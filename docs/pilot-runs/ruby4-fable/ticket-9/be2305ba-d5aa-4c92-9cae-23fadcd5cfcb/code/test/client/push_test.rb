# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "stringio"

# Push against a scripted stand-in for the API: checks the plan (what gets
# uploaded, what is left alone) and the report, independent of HTTP.
class ClientPushTest < Minitest::Test
  include TestHelpers

  Push = Syncbox::Client::Push
  Api = Syncbox::Client::Api

  class FakeApi
    attr_reader :puts, :list_calls, :closed

    def initialize(remote, put_sha: nil)
      @remote = remote
      @put_sha = put_sha
      @puts = []
      @list_calls = 0
      @closed = false
    end

    def list
      @list_calls += 1
      @remote.map { |key, sha| Api::RemoteBlob.new(key: key, size: 1, sha256: sha, modified_at: "2026-01-01T00:00:00.000Z") }
    end

    def put(key, path)
      content = File.binread(path)
      @puts << [key, content]
      Api::PutResult.new(key: key, size: content.bytesize, sha256: @put_sha || Digest::SHA256.hexdigest(content))
    end

    def close
      @closed = true
    end
  end

  def run_push(dir, api)
    out = StringIO.new
    err = StringIO.new
    summary = Push.new(dir: dir, api: api, out: out, err: err).call
    [summary, out.string, err.string]
  end

  def test_uploads_missing_and_changed_files_and_skips_identical_ones
    with_tmpdir do |dir|
      write(dir, "same.txt", "same")
      write(dir, "changed.txt", "v2")
      write(dir, "new/deep/file.bin", "\x00\x01".b)
      api = FakeApi.new({ "same.txt" => sha("same"), "changed.txt" => sha("v1"), "server-only.txt" => sha("s") })

      summary, out, err = run_push(dir, api)

      assert_equal [["changed.txt", "v2"], ["new/deep/file.bin", "\x00\x01".b]], api.puts
      assert_equal 1, api.list_calls, "the listing is fetched once, not per file"
      assert_equal 3, summary.scanned
      assert_equal 2, summary.uploaded
      assert_equal 1, summary.unchanged
      assert_equal <<~OUT, out
        uploaded changed.txt (changed, 2 bytes)
        uploaded new/deep/file.bin (new, 2 bytes)
        push done: 2 uploaded, 1 unchanged, 3 file(s) scanned
      OUT
      assert_equal "", err
      assert api.closed
    end
  end

  def test_second_push_of_an_unchanged_tree_uploads_nothing
    with_tmpdir do |dir|
      write(dir, "a", "A")
      write(dir, "b/c", "C")
      api = FakeApi.new({ "a" => sha("A"), "b/c" => sha("C") })

      summary, out, = run_push(dir, api)
      assert_equal [], api.puts
      assert_equal "push done: 0 uploaded, 2 unchanged, 2 file(s) scanned\n", out
      assert_equal [2, 0, 2], [summary.scanned, summary.uploaded, summary.unchanged]
    end
  end

  def test_same_size_different_content_counts_as_changed
    with_tmpdir do |dir|
      write(dir, "f", "abc")
      api = FakeApi.new({ "f" => sha("abd") })
      run_push(dir, api)
      assert_equal [["f", "abc"]], api.puts
    end
  end

  def test_empty_directory_pushes_nothing_and_still_reports
    with_tmpdir do |dir|
      api = FakeApi.new({})
      summary, out, = run_push(dir, api)
      assert_equal [], api.puts
      assert_equal [0, 0, 0], [summary.scanned, summary.uploaded, summary.unchanged]
      assert_equal "push done: 0 uploaded, 0 unchanged, 0 file(s) scanned\n", out
    end
  end

  def test_skipped_entries_are_reported_on_stderr
    with_tmpdir do |dir|
      write(dir, "f", "x")
      File.symlink(File.join(dir, "f"), File.join(dir, "link"))
      api = FakeApi.new({})
      _, out, err = run_push(dir, api)
      assert_equal [["f", "x"]], api.puts
      assert_equal "syncbox: warning: skipping link: symbolic links are not uploaded\n", err
      refute_match(/link/, out)
    end
  end

  def test_sha_mismatch_from_the_server_is_an_error
    with_tmpdir do |dir|
      write(dir, "f", "x")
      api = FakeApi.new({}, put_sha: "0" * 64)
      error = assert_raises(Push::Error) { run_push(dir, api) }
      assert_match(/f: server stored sha256 0{64}, expected #{sha('x')}/, error.message)
      assert api.closed, "the connection is closed even on failure"
    end
  end

  def test_scan_errors_abort_before_anything_is_uploaded
    with_tmpdir do |dir|
      write(dir, "ok", "x")
      File.write(File.join(dir, "bad-\xFF".b), "y")
      api = FakeApi.new({})
      assert_raises(Syncbox::Client::LocalTree::Error) { run_push(dir, api) }
      assert_equal [], api.puts
      assert_equal 0, api.list_calls
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
