# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

class StatusTest < Minitest::Test
  Blob = Syncbox::Client::Remote::Blob
  Status = Syncbox::Client::Status

  # In-memory stand-in for Remote that can only list: status must not upload,
  # download or delete anything, so any other call fails the test.
  class FakeRemote
    attr_reader :lists

    def initialize(contents = {})
      @blobs = contents.to_h { |key, content| [key, content.b] }
      @lists = 0
    end

    def list
      @lists += 1
      @blobs.to_h { |key, content| [key, Blob.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))] }
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_local_only_file_would_be_uploaded
    write("docs/new.txt", "local")

    status(FakeRemote.new)

    assert_equal "upload (not on server): docs/new.txt\nstatus: 1 to upload, 0 to download, 0 up to date\n", @out.string
    assert_equal "", @err.string
  end

  def test_server_only_blob_would_be_downloaded
    status(FakeRemote.new({ "photos/cat.jpg" => "remote" }))

    assert_equal "download (not local): photos/cat.jpg\nstatus: 0 to upload, 1 to download, 0 up to date\n",
                 @out.string
  end

  def test_file_with_different_content_is_listed_in_both_directions
    write("notes.txt", "local version")
    write("same-size", "aaa")

    status(FakeRemote.new({ "notes.txt" => "server version", "same-size" => "bbb" }))

    assert_equal "upload (content differs): notes.txt\nupload (content differs): same-size\n" \
                 "download (content differs): notes.txt\ndownload (content differs): same-size\n" \
                 "status: 2 to upload, 2 to download, 0 up to date\n", @out.string
  end

  def test_mixed_directory
    write("same", "same content")
    write("changed", "new")
    write("local-only", "l")
    write("dir/deep/local", "l")
    remote = FakeRemote.new({ "same" => "same content", "changed" => "old", "remote-only" => "r",
                              "dir/remote" => "r", "with space/✓ #1%?.txt" => "odd", "a\\b" => "backslash" })

    status(remote)

    assert_equal <<~OUT, @out.string
      upload (content differs): changed
      upload (not on server): dir/deep/local
      upload (not on server): local-only
      download (not local): a\\b
      download (content differs): changed
      download (not local): dir/remote
      download (not local): remote-only
      download (not local): with space/✓ #1%?.txt
      status: 3 to upload, 5 to download, 1 up to date
    OUT
    assert_equal 1, remote.lists
  end

  def test_nothing_to_do
    write("a", "x")
    write("b/c", "")

    status(FakeRemote.new({ "a" => "x", "b/c" => "" }))

    assert_equal "status: nothing to upload or download, 2 up to date\n", @out.string
  end

  def test_empty_directory_and_empty_server
    status(FakeRemote.new)

    assert_equal "status: nothing to upload or download, 0 up to date\n", @out.string
  end

  def test_changes_nothing_locally
    write("same", "same")
    write("changed", "local")
    write("local-only", "l")
    write("dir/sub/x", "x")
    Dir.mkdir(path("empty-dir"))
    File.chmod(0o640, path("changed"))
    File.utime(Time.at(0), Time.at(0), path("same"))
    File.symlink("same", path("link"))
    before = snapshot

    status(FakeRemote.new({ "same" => "same", "changed" => "server", "remote-only" => "r", "new-dir/deep/f" => "f",
                            "dir/sub/y" => "y", "empty-dir/z" => "z" }))

    assert_equal before, snapshot
    assert_match(/status: 3 to upload, 5 to download, 1 up to date/, @out.string)
  end

  def test_symlinks_and_special_files_are_skipped_like_push_and_pull_skip_them
    outside = Dir.mktmpdir
    write("file", "x")
    File.symlink("file", path("link"))
    File.symlink(outside, path("linked-dir"))
    File.mkfifo(path("fifo"))
    remote = FakeRemote.new({ "file" => "x", "link" => "evil", "linked-dir/target" => "evil", "fifo" => "evil" })

    status(remote)

    assert_equal "status: nothing to upload or download, 1 up to date\n", @out.string
    # The local entries are reported in directory order.
    assert_equal ["syncbox: skipping fifo: not a regular file", "syncbox: skipping link: symbolic link",
                  "syncbox: skipping linked-dir/target: linked-dir is a symbolic link",
                  "syncbox: skipping linked-dir: symbolic link"], @err.string.lines(chomp: true).sort
    assert_equal [], Dir.children(outside)
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_keys_outside_the_directory_are_rejected
    ["../escape", "/etc/passwd", "a//b", "a/.", ""].each do |bad|
      error = assert_raises(Syncbox::Client::Error, bad.inspect) { status(FakeRemote.new({ "ok" => "x", bad => "evil" })) }

      assert_equal "server listed a key that is not a path inside the directory: #{bad.inspect}", error.message
      assert_equal "", @out.string
    end
  end

  def test_unreadable_file_fails_alone
    skip "root ignores permission bits" if Process.uid.zero?
    write("secret", "old")
    write("z", "local")
    File.chmod(0o000, path("secret"))

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { status(FakeRemote.new({ "secret" => "new", "y" => "y" })) }

    assert_equal "status incomplete: 1 failed", error.message
    assert_equal ["cannot read secret: Permission denied"], error.failures
    assert_equal "upload (not on server): z\ndownload (not local): y\nstatus: 1 to upload, 1 to download, 0 up to date, 1 failed\n",
                 @out.string
  ensure
    File.chmod(0o644, path("secret"))
  end

  def test_directory_must_exist
    file = path("file")
    File.write(file, "")

    [path("missing"), file].each do |dir|
      error = assert_raises(Syncbox::Client::Error) { Status.new(dir, FakeRemote.new, out: @out, err: @err).run }
      assert_equal "not a directory: #{dir}", error.message
    end
  end

  private

  def status(remote)
    Status.new(@dir, remote, out: @out, err: @err).run
  end

  def path(key)
    File.join(@dir, key)
  end

  def write(key, content)
    FileUtils.mkdir_p(File.dirname(path(key)))
    File.binwrite(path(key), content)
  end

  # Everything under the directory: {relative path => [type, mode, mtime, content or link target]}.
  def snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).reject { |rel| File.basename(rel) == "." }.sort.to_h do |rel|
      full = path(rel)
      stat = File.lstat(full)
      detail = if stat.symlink? then File.readlink(full)
               elsif stat.file? then File.binread(full)
               end
      [rel, [stat.ftype, stat.mode, stat.mtime, detail]]
    end
  end
end
