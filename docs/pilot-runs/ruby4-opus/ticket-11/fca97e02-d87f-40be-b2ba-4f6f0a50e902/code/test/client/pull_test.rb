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

    # +fail_on+ makes get of those keys raise after sending part of the
    # blob; from the +unreachable_from+ key on, the server is unreachable;
    # +gone+ keys are listed but no longer found when downloaded.
    def initialize(contents = {}, fail_on: [], unreachable_from: nil, gone: [])
      @blobs = contents.to_h { |key, content| [key, content.b] }
      @downloads = []
      @fail_on = fail_on
      @unreachable_from = unreachable_from
      @gone = gone
    end

    def list
      @blobs.to_h { |key, content| [key, Blob.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))] }
    end

    def get(key)
      raise Syncbox::Client::Remote::NotFound, "cannot download #{key}: not found on the server" if @gone.include?(key)

      @downloads << key
      if @unreachable_from && key >= @unreachable_from
        raise Syncbox::Client::Remote::Unreachable, "cannot download #{key}: server is unreachable"
      end

      content = @blobs.fetch(key)
      content.bytes.each_slice(1000) do |slice|
        yield slice.pack("C*")
        raise Syncbox::Client::Error, "cannot download #{key}: connection to server failed" if @fail_on.include?(key)
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

  def test_directory_in_the_way_of_a_file_fails_alone
    FileUtils.mkdir_p(path("docs/sub"))
    remote = FakeRemote.new({ "a" => "a", "docs" => "x", "z" => "z" })

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { pull(remote) }

    assert_equal "pull incomplete: 1 failed", error.message
    assert_equal ["cannot write docs: a directory is in the way"], error.failures
    assert File.directory?(path("docs/sub"))
    assert_equal({ "a" => "a", "z" => "z" }, local_files)
    assert_equal "downloaded a\ndownloaded z\npull: 2 downloaded, 0 up to date, 1 failed\n", @out.string
  end

  def test_file_in_the_way_of_a_directory_fails_alone
    write("docs", "a file")
    remote = FakeRemote.new({ "docs/readme.txt" => "x", "z" => "z" })

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { pull(remote) }

    assert_equal ["cannot write docs/readme.txt: docs is a file, not a directory"], error.failures
    assert_equal "a file", File.read(path("docs"))
    assert_equal %w[z], remote.downloads
  end

  def test_failed_download_keeps_the_old_file_and_does_not_stop_the_others
    write("a", "old a")
    write("b", "old b")
    content = Random.new(2).bytes(5000)
    remote = FakeRemote.new({ "a" => "new a", "b" => content, "c" => "c" }, fail_on: ["b"])

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { pull(remote) }

    assert_equal "pull incomplete: 1 failed", error.message
    assert_equal ["cannot download b: connection to server failed"], error.failures
    assert_equal({ "a" => "new a", "b" => "old b", "c" => "c" }, local_files)
    assert_equal %w[a b c], Dir.children(@dir).sort, "no temporary file is left behind"
    assert_equal "downloaded a\ndownloaded c\npull: 2 downloaded, 0 up to date, 1 failed\n", @out.string
  end

  def test_unreachable_server_stops_the_downloads
    remote = FakeRemote.new({ "a" => "a", "b" => "b", "c" => "c", "d" => "d" }, unreachable_from: "b")

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { pull(remote) }

    assert_equal "pull incomplete: 1 failed, 2 not attempted (server unreachable)", error.message
    assert_equal ["cannot download b: server is unreachable"], error.failures
    assert_equal %w[a b], remote.downloads, "nothing is tried once the server is unreachable"
    assert_equal({ "a" => "a" }, local_files)
    assert_equal "downloaded a\npull: 1 downloaded, 0 up to date, 1 failed, 2 not attempted\n", @out.string
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

  def test_unwritable_directory_fails_alone
    skip "root ignores permission bits" if Process.uid.zero?
    Dir.mkdir(path("locked"))
    File.chmod(0o555, path("locked"))
    remote = FakeRemote.new({ "locked/f" => "x", "z" => "z" })

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { pull(remote) }

    assert_equal ["cannot write locked/f: Permission denied"], error.failures
    assert_equal [], Dir.children(path("locked"))
    assert_equal "z", File.read(path("z"))
  ensure
    File.chmod(0o755, path("locked"))
  end

  def test_unreadable_local_file_fails_alone
    skip "root ignores permission bits" if Process.uid.zero?
    write("secret", "old")
    File.chmod(0o000, path("secret"))
    remote = FakeRemote.new({ "a" => "a", "secret" => "new" })

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { pull(remote) }

    assert_equal ["cannot read secret: Permission denied"], error.failures
    assert_equal %w[a], remote.downloads
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
