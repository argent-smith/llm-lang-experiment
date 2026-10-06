# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "stringio"

# Pull against a scripted stand-in for the API: checks the plan (what gets
# downloaded, what is left alone), the files written and the report,
# independent of HTTP.
class ClientPullTest < Minitest::Test
  include TestHelpers

  Pull = Syncbox::Client::Pull
  Api = Syncbox::Client::Api
  LocalTree = Syncbox::Client::LocalTree

  class FakeApi
    attr_reader :gets, :list_calls, :closed

    # +remote+ maps key => content; +serve+ (key => content) overrides what
    # GET actually returns, to simulate a blob replaced after the listing.
    def initialize(remote, serve: {})
      @remote = remote
      @serve = serve
      @gets = []
      @list_calls = 0
      @closed = false
    end

    def list
      @list_calls += 1
      @remote.map do |key, content|
        Api::RemoteBlob.new(key: key, size: content.bytesize,
                            sha256: Digest::SHA256.hexdigest(content), modified_at: "2026-01-01T00:00:00.000Z")
      end
    end

    def get(key, path)
      @gets << [key, path]
      content = @serve.fetch(key) { @remote.fetch(key) }
      File.binwrite(path, content)
      Api::GetResult.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))
    end

    def close
      @closed = true
    end
  end

  def run_pull(dir, api)
    out = StringIO.new
    err = StringIO.new
    summary = Pull.new(dir: dir, api: api, out: out, err: err).call
    [summary, out.string, err.string]
  end

  def test_downloads_missing_and_changed_blobs_and_skips_identical_ones
    with_tmpdir do |dir|
      write(dir, "same.txt", "same")
      write(dir, "changed.txt", "v1")
      write(dir, "local-only.txt", "mine")
      api = FakeApi.new({ "same.txt" => "same", "changed.txt" => "v2", "new/deep/file.bin" => "\x00\x01".b })

      summary, out, err = run_pull(dir, api)

      assert_equal ["changed.txt", "new/deep/file.bin"], api.gets.map(&:first)
      assert_equal 1, api.list_calls, "the listing is fetched once, not per blob"
      assert_equal [3, 2, 1], [summary.listed, summary.downloaded, summary.unchanged]
      assert_equal <<~OUT, out
        downloaded changed.txt (changed, 2 bytes)
        downloaded new/deep/file.bin (new, 2 bytes)
        pull done: 2 downloaded, 1 unchanged, 3 blob(s) listed
      OUT
      assert_equal "", err
      assert api.closed

      assert_equal "v2", File.binread(File.join(dir, "changed.txt"))
      assert_equal "\x00\x01".b, File.binread(File.join(dir, "new/deep/file.bin"))
      assert_equal "same", File.binread(File.join(dir, "same.txt"))
      assert_equal "mine", File.binread(File.join(dir, "local-only.txt")), "pull never deletes or touches local-only files"
      assert_equal ["changed.txt", "local-only.txt", "new/deep/file.bin", "same.txt"], LocalTree.scan(dir).map(&:key),
                   "no staging files are left behind"
    end
  end

  def test_second_pull_of_an_unchanged_tree_downloads_nothing
    with_tmpdir do |dir|
      write(dir, "a", "A")
      write(dir, "b/c", "C")
      api = FakeApi.new({ "a" => "A", "b/c" => "C" })

      summary, out, = run_pull(dir, api)
      assert_equal [], api.gets
      assert_equal "pull done: 0 downloaded, 2 unchanged, 2 blob(s) listed\n", out
      assert_equal [2, 0, 2], [summary.listed, summary.downloaded, summary.unchanged]
    end
  end

  def test_same_size_different_content_counts_as_changed
    with_tmpdir do |dir|
      write(dir, "f", "abc")
      api = FakeApi.new({ "f" => "abd" })
      run_pull(dir, api)
      assert_equal ["f"], api.gets.map(&:first)
      assert_equal "abd", File.read(File.join(dir, "f"))
    end
  end

  def test_empty_listing_downloads_nothing_and_still_reports
    with_tmpdir do |dir|
      write(dir, "keep", "k")
      api = FakeApi.new({})
      summary, out, = run_pull(dir, api)
      assert_equal [], api.gets
      assert_equal [0, 0, 0], [summary.listed, summary.downloaded, summary.unchanged]
      assert_equal "pull done: 0 downloaded, 0 unchanged, 0 blob(s) listed\n", out
      assert_equal "k", File.read(File.join(dir, "keep"))
    end
  end

  def test_staging_file_is_next_to_the_target_and_renamed_into_place
    with_tmpdir do |dir|
      api = FakeApi.new({ "sub/dir/f.txt" => "x" })
      run_pull(dir, api)
      _, staging = api.gets.first
      assert_equal File.join(dir, "sub/dir"), File.dirname(staging)
      assert_match(/\A\.syncbox-tmp-\h{16}\z/, File.basename(staging))
      refute File.exist?(staging)
      assert_equal "x", File.read(File.join(dir, "sub/dir/f.txt"))
    end
  end

  def test_replacing_a_file_keeps_its_permission_bits
    with_tmpdir do |dir|
      write(dir, "run.sh", "old")
      File.chmod(0o755, File.join(dir, "run.sh"))
      run_pull(dir, FakeApi.new({ "run.sh" => "new", "plain" => "p" }))
      assert_equal 0o755, File.stat(File.join(dir, "run.sh")).mode & 0o7777
      assert_equal "new", File.read(File.join(dir, "run.sh"))
      refute File.stat(File.join(dir, "plain")).executable?
    end
  end

  def test_sha_mismatch_leaves_the_old_file_intact_and_no_staging_file
    with_tmpdir do |dir|
      write(dir, "f", "old")
      api = FakeApi.new({ "f" => "listed" }, serve: { "f" => "actually served" })
      error = assert_raises(Pull::Error) { run_pull(dir, api) }
      assert_match(/\Af: downloaded sha256 #{sha('actually served')}, expected #{sha('listed')} from the listing/, error.message)
      assert_equal "old", File.read(File.join(dir, "f"))
      assert_equal ["f"], Dir.children(dir), "the staging file must be removed"
      assert api.closed, "the connection is closed even on failure"
    end
  end

  def test_unsafe_keys_from_the_server_are_refused_before_anything_is_written
    with_tmpdir do |dir|
      ["../escape", "/abs", "a/../b", "./x", "a//b", "", "nul\0"].each do |bad|
        api = FakeApi.new({ bad => "evil" })
        error = assert_raises(LocalTree::Error, bad.inspect) { run_pull(dir, api) }
        assert_match(/refusing key #{Regexp.escape(bad.inspect)} from the server/, error.message)
        assert_equal [], api.gets, "nothing is downloaded for #{bad.inspect}"
        assert_equal [], Dir.children(dir), "nothing is written for #{bad.inspect}"
      end
      refute File.exist?(File.join(File.dirname(dir), "escape"))
    end
  end

  def test_directory_or_symlink_in_the_way_is_an_error_and_is_left_alone
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "d"))
      error = assert_raises(LocalTree::Error) { run_pull(dir, FakeApi.new({ "d" => "x" })) }
      assert_match(/\Ad: a directory is in the way of the file/, error.message)
      assert File.directory?(File.join(dir, "d"))

      write(dir, "real", "r")
      File.symlink("real", File.join(dir, "link"))
      error = assert_raises(LocalTree::Error) { run_pull(dir, FakeApi.new({ "link" => "x" })) }
      assert_match(/\Alink: a symbolic link is in the way of the file/, error.message)
      assert_equal "r", File.read(File.join(dir, "real"))
      assert File.symlink?(File.join(dir, "link"))

      # A key below a symlinked directory would write outside the directory
      # through the link; a key below a regular file cannot be written at all.
      outside = Dir.mktmpdir("syncbox-outside-")
      begin
        File.symlink(outside, File.join(dir, "dirlink"))
        error = assert_raises(LocalTree::Error) { run_pull(dir, FakeApi.new({ "dirlink/inner.txt" => "x" })) }
        assert_match(%r{\Adirlink/inner\.txt: a symbolic link is in the way \(dirlink\)}, error.message)
        assert_equal [], Dir.children(outside), "nothing may be written through the link"
      ensure
        FileUtils.rm_rf(outside)
      end

      error = assert_raises(LocalTree::Error) { run_pull(dir, FakeApi.new({ "real/inner.txt" => "x" })) }
      assert_match(%r{\Areal/inner\.txt: real is in the way and is not a directory}, error.message)
      assert_equal "r", File.read(File.join(dir, "real"))
    end
  end

  def test_missing_directory_is_an_error_before_the_listing_is_fetched
    with_tmpdir do |dir|
      api = FakeApi.new({ "f" => "x" })
      error = assert_raises(LocalTree::Error) { run_pull(File.join(dir, "nope"), api) }
      assert_match(/not a directory: .*nope/, error.message)
      assert_equal 0, api.list_calls
      assert api.closed
    end
  end

  private

  def sha(content)
    Digest::SHA256.hexdigest(content)
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
