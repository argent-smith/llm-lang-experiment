# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "stringio"

# Status against a scripted stand-in for the API: checks the comparison
# (which key lands in which group), the report and — above all — that
# nothing is touched on either side, independent of HTTP.
class ClientStatusTest < Minitest::Test
  include TestHelpers

  Status = Syncbox::Client::Status
  Api = Syncbox::Client::Api

  # Only #list and #close exist. Anything that would change the server (PUT,
  # DELETE) or fetch a body (GET /blobs/{key}) fails loudly: status has no
  # business calling it.
  class ReadOnlyFakeApi
    attr_reader :list_calls, :closed

    def initialize(remote)
      @remote = remote
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

    def put(*)
      raise "status must not PUT"
    end

    def get(*)
      raise "status must not GET a blob"
    end

    def delete(*)
      raise "status must not DELETE"
    end

    def close
      @closed = true
    end
  end

  def run_status(dir, api)
    out = StringIO.new
    err = StringIO.new
    report = Status.new(dir: dir, api: api, out: out, err: err).call
    [report, out.string, err.string]
  end

  def test_local_only_file_is_an_upload
    with_tmpdir do |dir|
      write(dir, "new/deep/file.bin", "\x00\x01".b)
      api = ReadOnlyFakeApi.new({})

      report, out, err = run_status(dir, api)

      assert_equal ["new/deep/file.bin"], report.uploads.map(&:key)
      assert_equal [[], [], 0], [report.downloads, report.differing, report.unchanged]
      assert_equal <<~OUT, out
        upload    new/deep/file.bin  (missing on server, 2 bytes)
        status: 1 to upload, 0 to download, 0 differ on both sides, 0 unchanged (dry run: nothing was changed)
      OUT
      assert_equal "", err
    end
  end

  def test_server_only_blob_is_a_download
    with_tmpdir do |dir|
      api = ReadOnlyFakeApi.new({ "server-only.txt" => "seven!!" })

      report, out, = run_status(dir, api)

      assert_equal ["server-only.txt"], report.downloads.map(&:key)
      assert_equal [[], [], 0], [report.uploads, report.differing, report.unchanged]
      assert_equal <<~OUT, out
        download  server-only.txt  (missing locally, 7 bytes)
        status: 0 to upload, 1 to download, 0 differ on both sides, 0 unchanged (dry run: nothing was changed)
      OUT
      assert_equal [], Dir.children(dir), "nothing is downloaded"
    end
  end

  def test_file_with_different_content_on_both_sides_differs_in_both_directions
    with_tmpdir do |dir|
      write(dir, "changed.txt", "local version")
      api = ReadOnlyFakeApi.new({ "changed.txt" => "server!" })

      report, out, = run_status(dir, api)

      assert_equal ["changed.txt"], report.differing.map(&:key)
      assert_equal [[], [], 0], [report.uploads, report.downloads, report.unchanged]
      assert_equal <<~OUT, out
        differs   changed.txt  (local 13 bytes, server 7 bytes; push would upload, pull would download)
        status: 0 to upload, 0 to download, 1 differs on both sides, 0 unchanged (dry run: nothing was changed)
      OUT
      assert_equal "local version", File.read(File.join(dir, "changed.txt"))
    end
  end

  def test_same_size_different_content_is_reported_as_differing
    with_tmpdir do |dir|
      write(dir, "f", "abc")
      report, = run_status(dir, ReadOnlyFakeApi.new({ "f" => "abd" }))
      assert_equal ["f"], report.differing.map(&:key)
      assert_equal 0, report.unchanged
    end
  end

  def test_mixed_tree_groups_every_key_once_and_lists_uploads_downloads_then_differing
    with_tmpdir do |dir|
      write(dir, "same.txt", "same")
      write(dir, "changed.txt", "v2")
      write(dir, "b-local.txt", "mine")
      write(dir, "a-local.txt", "mine too")
      api = ReadOnlyFakeApi.new({ "same.txt" => "same", "changed.txt" => "v1",
                                  "z-remote.txt" => "s", "docs/y-remote.txt" => "ss" })

      report, out, err = run_status(dir, api)

      assert_equal 1, api.list_calls, "the listing is fetched once"
      assert_equal ["a-local.txt", "b-local.txt"], report.uploads.map(&:key)
      assert_equal ["docs/y-remote.txt", "z-remote.txt"], report.downloads.map(&:key)
      assert_equal ["changed.txt"], report.differing.map(&:key)
      assert_equal 1, report.unchanged
      refute report.in_sync?
      assert_equal <<~OUT, out
        upload    a-local.txt  (missing on server, 8 bytes)
        upload    b-local.txt  (missing on server, 4 bytes)
        download  docs/y-remote.txt  (missing locally, 2 bytes)
        download  z-remote.txt  (missing locally, 1 bytes)
        differs   changed.txt  (local 2 bytes, server 2 bytes; push would upload, pull would download)
        status: 2 to upload, 2 to download, 1 differs on both sides, 1 unchanged (dry run: nothing was changed)
      OUT
      assert_equal "", err
      assert api.closed
    end
  end

  def test_identical_trees_are_in_sync
    with_tmpdir do |dir|
      write(dir, "a", "A")
      write(dir, "b/c", "C")
      report, out, = run_status(dir, ReadOnlyFakeApi.new({ "a" => "A", "b/c" => "C" }))
      assert report.in_sync?
      assert_equal 2, report.unchanged
      assert_equal "status: in sync, 2 file(s) identical on both sides (dry run: nothing was changed)\n", out
    end
  end

  def test_empty_directory_and_empty_server_are_in_sync
    with_tmpdir do |dir|
      report, out, = run_status(dir, ReadOnlyFakeApi.new({}))
      assert report.in_sync?
      assert_equal "status: in sync, 0 file(s) identical on both sides (dry run: nothing was changed)\n", out
    end
  end

  def test_status_changes_nothing_locally
    with_tmpdir do |dir|
      write(dir, "same.txt", "same")
      write(dir, "changed.txt", "v2")
      write(dir, "local-only.txt", "mine")
      before = snapshot(dir)
      api = ReadOnlyFakeApi.new({ "same.txt" => "same", "changed.txt" => "v1", "remote-only.txt" => "r", "sub/new.txt" => "n" })

      run_status(dir, api)

      assert_equal before, snapshot(dir), "status must not create, modify or remove anything under the directory"
      assert api.closed
    end
  end

  def test_skipped_entries_are_reported_on_stderr_and_a_symlink_in_the_way_is_noted
    with_tmpdir do |dir|
      write(dir, "f", "x")
      File.symlink(File.join(dir, "f"), File.join(dir, "link"))
      FileUtils.mkdir_p(File.join(dir, "d"))
      api = ReadOnlyFakeApi.new({ "f" => "x", "link" => "l", "d" => "dd", "d/inner" => "i" })

      report, out, err = run_status(dir, api)

      assert_equal "syncbox: warning: skipping link: symbolic links are not uploaded\n", err
      assert_equal ["d", "d/inner", "link"], report.downloads.map(&:key)
      assert_equal <<~OUT, out
        download  d  (missing locally, 2 bytes; pull would fail: a directory is in the way of the file)
        download  d/inner  (missing locally, 1 bytes)
        download  link  (missing locally, 1 bytes; pull would fail: a symbolic link is in the way of the file)
        status: 0 to upload, 3 to download, 0 differ on both sides, 1 unchanged (dry run: nothing was changed)
      OUT
      assert File.symlink?(File.join(dir, "link"))
      assert File.directory?(File.join(dir, "d"))
    end
  end

  def test_unsafe_keys_from_the_server_are_listed_with_a_note_not_resolved
    with_tmpdir do |dir|
      api = ReadOnlyFakeApi.new({ "../escape" => "evil", "ok.txt" => "fine" })
      report, out, = run_status(dir, api)
      assert_equal ["../escape", "ok.txt"], report.downloads.map(&:key)
      assert_match(%r{\Adownload  \.\./escape  \(missing locally, 4 bytes; pull would fail: refusing key "\.\./escape" from the server: contains a \. or \.\. segment\)$}, out)
      assert_equal [], Dir.children(dir)
      refute File.exist?(File.join(File.dirname(dir), "escape"))
    end
  end

  def test_missing_directory_is_an_error_before_the_listing_is_fetched
    with_tmpdir do |dir|
      api = ReadOnlyFakeApi.new({ "f" => "x" })
      error = assert_raises(Syncbox::Client::LocalTree::Error) { run_status(File.join(dir, "nope"), api) }
      assert_match(/not a directory: .*nope/, error.message)
      assert_equal 0, api.list_calls
      assert api.closed
    end
  end

  # An entry that cannot be scanned cannot be compared: it is reported as a
  # failure, the rest of the comparison still happens, and the report says it
  # is incomplete (the Runner then exits non-zero).
  def test_an_entry_that_cannot_be_scanned_is_reported_and_the_rest_is_still_compared
    with_tmpdir do |dir|
      write(dir, "ok", "x")
      write(dir, "same", "same")
      File.write(File.join(dir, "bad-\xFF".b), "y")
      api = ReadOnlyFakeApi.new({ "same" => "same", "remote" => "r" })

      report, out, err = run_status(dir, api)

      assert_equal 1, api.list_calls
      assert_equal 1, report.failed
      assert_equal ["ok"], report.uploads.map(&:key)
      assert_equal ["remote"], report.downloads.map(&:key)
      assert_equal <<~OUT, out
        upload    ok  (missing on server, 1 bytes)
        download  remote  (missing locally, 1 bytes)
        status: 1 to upload, 1 to download, 0 differ on both sides, 1 unchanged, 1 not compared (dry run: nothing was changed)
      OUT
      assert_equal <<~ERR, err
        syncbox: failed "bad-\\xFF": file name is not valid UTF-8 and cannot be a key: "bad-\\xFF"
        syncbox: status incomplete: 1 of 3 file(s) failed
        syncbox:   "bad-\\xFF": file name is not valid UTF-8 and cannot be a key: "bad-\\xFF"
      ERR
    end
  end

  def test_an_unreadable_file_is_reported_and_an_otherwise_identical_tree_is_not_called_in_sync
    skip "root can read anything" if Process.uid.zero?

    with_tmpdir do |dir|
      write(dir, "a", "A")
      write(dir, "secret", "s")
      File.chmod(0o000, File.join(dir, "secret"))
      begin
        report, out, err = run_status(dir, ReadOnlyFakeApi.new({ "a" => "A", "secret" => "s" }))
        assert_equal 1, report.failed
        assert report.in_sync?, "the files that could be compared are identical"
        assert_equal "status: 0 to upload, 0 to download, 0 differ on both sides, 1 unchanged, 1 not compared " \
                     "(dry run: nothing was changed)\n", out
        assert_match(/\Asyncbox: failed secret: cannot read secret: Permission denied/, err)
        assert_match(/status incomplete: 1 of 2 file\(s\) failed/, err)
      ensure
        File.chmod(0o600, File.join(dir, "secret"))
      end
    end
  end

  private

  # Every entry under +dir+ with its type, content hash and mtime — enough to
  # notice any creation, modification or removal.
  def snapshot(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.map do |rel|
      path = File.join(dir, rel)
      stat = File.lstat(path)
      [rel, stat.ftype, stat.file? ? Digest::SHA256.file(path).hexdigest : nil, stat.mtime]
    end
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
