# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

class PushTest < Minitest::Test
  Blob = Syncbox::Client::Remote::Blob

  # In-memory stand-in for Remote.
  class FakeRemote
    attr_reader :blobs, :uploads

    def initialize(contents = {}, fail_on: nil)
      @blobs = contents.to_h { |key, content| [key, content.b] }
      @uploads = []
      @fail_on = fail_on
    end

    def list
      @blobs.to_h { |key, content| [key, Blob.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))] }
    end

    def put(key, io)
      raise Syncbox::Client::Error, "cannot upload #{key}: server answered 500" if key == @fail_on

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

  def test_unreadable_file_stops_the_push
    skip "root ignores permission bits" if Process.uid.zero?
    write("a", "x")
    write("b", "secret")
    File.chmod(0o000, File.join(@dir, "b"))
    remote = FakeRemote.new({ "b" => "stored" })

    error = assert_raises(Syncbox::Client::Error) { push(remote) }

    assert_equal "cannot read b: Permission denied", error.message
    assert_equal [], remote.uploads
  end

  def test_failed_upload_stops_the_push
    write("a", "x")
    write("b", "y")
    write("c", "z")
    remote = FakeRemote.new(fail_on: "b")

    error = assert_raises(Syncbox::Client::Error) { push(remote) }

    assert_match(/cannot upload b/, error.message)
    assert_equal %w[a], remote.uploads
    assert_equal "uploaded a\n", @out.string
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
