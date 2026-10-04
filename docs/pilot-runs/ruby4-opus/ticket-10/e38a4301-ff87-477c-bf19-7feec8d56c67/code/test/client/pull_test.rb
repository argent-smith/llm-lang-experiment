# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

class PullTest < Minitest::Test
  Blob = Syncbox::Client::Remote::Blob
  Pull = Syncbox::Client::Pull

  # In-memory stand-in for Remote.
  class FakeRemote
    attr_reader :downloads

    # +fail_on+ makes get of that key raise after sending part of the blob;
    # +gone+ keys are listed but no longer found when downloaded.
    def initialize(contents = {}, fail_on: nil, gone: [])
      @blobs = contents.to_h { |key, content| [key, content.b] }
      @downloads = []
      @fail_on = fail_on
      @gone = gone
    end

    def list
      @blobs.to_h { |key, content| [key, Blob.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))] }
    end

    def get(key)
      raise Syncbox::Client::Remote::NotFound, "cannot download #{key}: not found on the server" if @gone.include?(key)

      @downloads << key
      content = @blobs.fetch(key)
      content.bytes.each_slice(1000) do |slice|
        yield slice.pack("C*")
        raise Syncbox::Client::Error, "cannot download #{key}: server is unreachable" if key == @fail_on
      end
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

  def test_downloads_every_blob_into_an_empty_directory
    content = Random.new(1).bytes(200_000)
    remote = FakeRemote.new({ "a.txt" => "hello", "docs/deep/data.bin" => content, "empty" => "",
                              "with space/✓ #1%?.txt" => "odd", "a\\b" => "backslash" })

    pull(remote)

    assert_equal({ "a.txt" => "hello", "a\\b" => "backslash", "docs/deep/data.bin" => content, "empty" => "",
                   "with space/✓ #1%?.txt" => "odd" }, local_files)
    assert_equal "downloaded a.txt\ndownloaded a\\b\ndownloaded docs/deep/data.bin\ndownloaded empty\n" \
                 "downloaded with space/✓ #1%?.txt\npull: 5 downloaded, 0 up to date\n", @out.string
    assert_equal "", @err.string
  end

  def test_downloads_only_missing_and_changed_files
    write("same", "same content")
    write("changed", "older")
    write("same-size", "aaa")
    write("local-only", "kept")
    remote = FakeRemote.new({ "same" => "same content", "changed" => "new", "same-size" => "bbb", "missing" => "m" })

    pull(remote)

    assert_equal %w[changed missing same-size], remote.downloads
    assert_equal({ "same" => "same content", "changed" => "new", "same-size" => "bbb", "missing" => "m",
                   "local-only" => "kept" }, local_files)
    assert_equal "downloaded changed\ndownloaded missing\ndownloaded same-size\npull: 3 downloaded, 1 up to date\n",
                 @out.string
  end

  def test_unchanged_file_is_left_untouched
    write("same", "x")
    File.utime(Time.at(0), Time.at(0), path("same"))

    pull(FakeRemote.new({ "same" => "x" }))

    assert_equal Time.at(0), File.mtime(path("same"))
  end

  def test_second_pull_downloads_nothing
    remote = FakeRemote.new({ "a" => "x", "b/c" => "y" })
    pull(remote)
    @out.truncate(0)
    @out.rewind

    pull(remote)

    assert_equal %w[a b/c], remote.downloads
    assert_equal "pull: 0 downloaded, 2 up to date\n", @out.string
  end

  def test_replaced_file_keeps_its_permissions
    write("script", "old")
    File.chmod(0o751, path("script"))

    pull(FakeRemote.new({ "script" => "new", "fresh" => "f" }))

    assert_equal "new", File.binread(path("script"))
    assert_equal 0o751, File.stat(path("script")).mode & 0o7777
    assert_equal 0o666 & ~File.umask, File.stat(path("fresh")).mode & 0o7777
  end

  def test_keys_outside_the_directory_are_rejected_before_anything_is_written
    ["../escape", "a/../../escape", "/etc/passwd", "a//b", "./a", "a/.", "a/", "", "a\0b"].each do |bad|
      remote = FakeRemote.new({ "a-good" => "x", bad => "evil" })

      error = assert_raises(Syncbox::Client::Error, bad.inspect) { pull(remote) }

      assert_equal "server listed a key that is not a path inside the directory: #{bad.inspect}", error.message
      assert_equal [], remote.downloads
      assert_equal({}, local_files)
    end
  end

  def test_symlinks_on_the_way_are_not_followed
    outside = Dir.mktmpdir
    File.write(File.join(outside, "target"), "outside")
    File.symlink(outside, path("linked-dir"))
    File.symlink(File.join(outside, "target"), path("linked-file"))
    File.mkfifo(path("fifo"))
    remote = FakeRemote.new({ "linked-dir/target" => "evil", "linked-dir/new/x" => "evil", "linked-file" => "evil",
                              "fifo" => "evil", "ok" => "ok" })

    pull(remote)

    assert_equal %w[ok], remote.downloads
    assert_equal ["target"], Dir.children(outside)
    assert_equal "outside", File.read(File.join(outside, "target"))
    assert_predicate File.lstat(path("linked-file")), :symlink?
    assert_predicate File.lstat(path("fifo")), :pipe?
    assert_equal "syncbox: skipping fifo: fifo is a special file\n" \
                 "syncbox: skipping linked-dir/new/x: linked-dir is a symbolic link\n" \
                 "syncbox: skipping linked-dir/target: linked-dir is a symbolic link\n" \
                 "syncbox: skipping linked-file: linked-file is a symbolic link\n", @err.string
    assert_equal "downloaded ok\npull: 1 downloaded, 0 up to date\n", @out.string
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_directory_in_the_way_of_a_file_is_an_error
    FileUtils.mkdir_p(path("docs/sub"))

    error = assert_raises(Syncbox::Client::Error) { pull(FakeRemote.new({ "docs" => "x" })) }

    assert_equal "cannot write docs: a directory is in the way", error.message
    assert File.directory?(path("docs/sub"))
  end

  def test_file_in_the_way_of_a_directory_is_an_error
    write("docs", "a file")

    error = assert_raises(Syncbox::Client::Error) { pull(FakeRemote.new({ "docs/readme.txt" => "x" })) }

    assert_equal "cannot write docs/readme.txt: docs is a file, not a directory", error.message
    assert_equal "a file", File.read(path("docs"))
  end

  def test_failed_download_keeps_the_old_file_and_leaves_no_temporary_file
    write("a", "old a")
    write("b", "old b")
    content = Random.new(2).bytes(5000)
    remote = FakeRemote.new({ "a" => "new a", "b" => content, "c" => "c" }, fail_on: "b")

    error = assert_raises(Syncbox::Client::Error) { pull(remote) }

    assert_equal "cannot download b: server is unreachable", error.message
    assert_equal({ "a" => "new a", "b" => "old b" }, local_files)
    assert_equal %w[a b], Dir.children(@dir).sort
    assert_equal "downloaded a\n", @out.string
  end

  def test_blob_deleted_meanwhile_is_skipped
    remote = FakeRemote.new({ "a" => "x", "gone" => "y", "z" => "z" }, gone: ["gone"])

    pull(remote)

    assert_equal({ "a" => "x", "z" => "z" }, local_files)
    assert_equal "syncbox: skipping gone: deleted from the server meanwhile\n", @err.string
    assert_equal "downloaded a\ndownloaded z\npull: 2 downloaded, 0 up to date\n", @out.string
  end

  def test_blobs_in_the_clients_state_directory_are_skipped
    write(".syncbox/state.json", "mine")
    remote = FakeRemote.new({ ".syncbox" => "evil", ".syncbox/state.json" => "evil", "a" => "x" })

    pull(remote)

    assert_equal %w[a], remote.downloads
    assert_equal "mine", File.read(path(".syncbox/state.json"))
    assert_equal "syncbox: skipping .syncbox: .syncbox is reserved for the client's sync state\n" \
                 "syncbox: skipping .syncbox/state.json: .syncbox is reserved for the client's sync state\n", @err.string
    assert_equal "downloaded a\npull: 1 downloaded, 0 up to date\n", @out.string
  end

  def test_unwritable_directory_is_an_error
    skip "root ignores permission bits" if Process.uid.zero?
    Dir.mkdir(path("locked"))
    File.chmod(0o555, path("locked"))

    error = assert_raises(Syncbox::Client::Error) { pull(FakeRemote.new({ "locked/f" => "x" })) }

    assert_equal "cannot write locked/f: Permission denied", error.message
    assert_equal [], Dir.children(path("locked"))
  ensure
    File.chmod(0o755, path("locked"))
  end

  def test_unreadable_local_file_is_an_error
    skip "root ignores permission bits" if Process.uid.zero?
    write("secret", "old")
    File.chmod(0o000, path("secret"))

    error = assert_raises(Syncbox::Client::Error) { pull(FakeRemote.new({ "secret" => "new" })) }

    assert_equal "cannot read secret: Permission denied", error.message
  ensure
    File.chmod(0o644, path("secret"))
  end

  def test_directory_must_exist
    file = path("file")
    File.write(file, "")

    [path("missing"), file].each do |dir|
      error = assert_raises(Syncbox::Client::Error) { Pull.new(dir, FakeRemote.new, out: @out, err: @err).run }
      assert_equal "not a directory: #{dir}", error.message
    end
  end

  def test_safe_key
    ["a", "docs/readme.txt", ".hidden", "a..b", "...", "a\\..\\b", "✓"].each { |key| assert Pull.safe_key?(key), key }
    ["", "/a", "a/", "a//b", ".", "..", "a/..", "../a", "a/./b", "a\0", "\xFF".dup.force_encoding("UTF-8"), nil, 1]
      .each { |key| refute Pull.safe_key?(key), key.inspect }
  end

  private

  def pull(remote)
    Pull.new(@dir, remote, out: @out, err: @err).run
  end

  def path(key)
    File.join(@dir, key)
  end

  def write(key, content)
    FileUtils.mkdir_p(File.dirname(path(key)))
    File.binwrite(path(key), content)
  end

  # The regular files under the directory: {key => content}.
  def local_files
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir)
       .select { |key| File.file?(path(key)) && !File.symlink?(path(key)) }
       .to_h { |key| [key, File.binread(path(key))] }
  end
end
