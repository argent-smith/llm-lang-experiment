# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

class PushTest < Minitest::Test
  Blob = Syncbox::Client::Remote::Blob

  # In-memory stand-in for Remote.
  class FakeRemote
    attr_reader :blobs, :uploads, :attempts

    # Uploads of the +fail_on+ keys fail; from the +unreachable_from+ key
    # on, the server is unreachable.
    def initialize(contents = {}, fail_on: [], unreachable_from: nil)
      @blobs = contents.to_h { |key, content| [key, content.b] }
      @uploads = []
      @attempts = []
      @fail_on = fail_on
      @unreachable_from = unreachable_from
    end

    def list
      @blobs.to_h { |key, content| [key, Blob.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))] }
    end

    def put(key, io)
      @attempts << key
      raise Syncbox::Client::Error, "cannot upload #{key}: server answered 500" if @fail_on.include?(key)
      if @unreachable_from && key >= @unreachable_from
        raise Syncbox::Client::Remote::Unreachable, "cannot upload #{key}: server is unreachable"
      end

      @uploads << key
      @blobs[key] = io.read
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

  def test_uploads_every_file_to_an_empty_server
    content = Random.new(1).bytes(200_000)
    write("a.txt", "hello")
    write("docs/data.bin", content)
    write("empty", "")
    remote = FakeRemote.new

    push(remote)

    assert_equal({ "a.txt" => "hello", "docs/data.bin" => content, "empty" => "" }, remote.blobs)
    assert_equal "uploaded a.txt\nuploaded docs/data.bin\nuploaded empty\npush: 3 uploaded, 0 up to date\n", @out.string
    assert_equal "", @err.string
  end

  def test_uploads_only_missing_and_changed_files
    write("same", "same content")
    write("changed", "new")
    write("same-size", "bbb")
    write("missing", "m")
    remote = FakeRemote.new({ "same" => "same content", "changed" => "older", "same-size" => "aaa", "remote-only" => "r" })

    push(remote)

    assert_equal %w[changed missing same-size], remote.uploads
    assert_equal({ "same" => "same content", "changed" => "new", "same-size" => "bbb", "remote-only" => "r", "missing" => "m" },
                 remote.blobs)
    assert_equal "uploaded changed\nuploaded missing\nuploaded same-size\npush: 3 uploaded, 1 up to date\n", @out.string
  end

  def test_second_push_uploads_nothing
    write("a", "x")
    write("b/c", "y")
    remote = FakeRemote.new
    push(remote)
    @out.truncate(0)
    @out.rewind

    push(remote)

    assert_equal %w[a b/c], remote.uploads
    assert_equal "push: 0 uploaded, 2 up to date\n", @out.string
  end

  def test_skipped_entries_are_reported_on_stderr
    write("file", "x")
    File.symlink("file", File.join(@dir, "link"))
    remote = FakeRemote.new

    push(remote)

    assert_equal %w[file], remote.uploads
    assert_equal "syncbox: skipping link: symbolic link\n", @err.string
  end

  def test_directory_must_exist
    file = File.join(@dir, "file")
    File.write(file, "")

    [File.join(@dir, "missing"), file].each do |dir|
      error = assert_raises(Syncbox::Client::Error) { Syncbox::Client::Push.new(dir, FakeRemote.new, out: @out, err: @err).run }
      assert_equal "not a directory: #{dir}", error.message
    end
  end

  def test_unreadable_file_fails_alone
    skip "root ignores permission bits" if Process.uid.zero?
    write("a", "x")
    write("b", "secret")
    write("c", "z")
    File.chmod(0o000, File.join(@dir, "b"))
    remote = FakeRemote.new({ "b" => "stored" })

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { push(remote) }

    assert_equal "push incomplete: 1 failed", error.message
    assert_equal ["cannot read b: Permission denied"], error.failures
    assert_equal %w[a c], remote.uploads
    assert_equal "uploaded a\nuploaded c\npush: 2 uploaded, 0 up to date, 1 failed\n", @out.string
  end

  def test_unreadable_directory_fails_alone
    skip "root ignores permission bits" if Process.uid.zero?
    write("a", "x")
    write("locked/secret", "s")
    write("z", "z")
    File.chmod(0o000, File.join(@dir, "locked"))
    remote = FakeRemote.new

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { push(remote) }

    assert_equal ["cannot read directory locked: Permission denied"], error.failures
    assert_equal %w[a z], remote.uploads
  ensure
    File.chmod(0o755, File.join(@dir, "locked"))
  end

  def test_failed_uploads_do_not_stop_the_others
    %w[a b c d].each { |key| write(key, key) }
    remote = FakeRemote.new(fail_on: %w[b d])

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { push(remote) }

    assert_equal "push incomplete: 2 failed", error.message
    assert_equal ["cannot upload b: server answered 500", "cannot upload d: server answered 500"], error.failures
    assert_equal %w[a c], remote.uploads
    assert_equal "uploaded a\nuploaded c\npush: 2 uploaded, 0 up to date, 2 failed\n", @out.string
  end

  def test_unreachable_server_stops_the_uploads
    %w[a b c d].each { |key| write(key, key) }
    remote = FakeRemote.new(unreachable_from: "b")

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { push(remote) }

    assert_equal "push incomplete: 1 failed, 2 not attempted (server unreachable)", error.message
    assert_equal ["cannot upload b: server is unreachable"], error.failures
    assert_equal %w[a], remote.uploads
    assert_equal %w[a b], remote.attempts, "nothing is tried once the server is unreachable"
    assert_equal "uploaded a\npush: 1 uploaded, 0 up to date, 1 failed, 2 not attempted\n", @out.string
  end

  private

  def push(remote)
    Syncbox::Client::Push.new(@dir, remote, out: @out, err: @err).run
  end

  def write(key, content)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
