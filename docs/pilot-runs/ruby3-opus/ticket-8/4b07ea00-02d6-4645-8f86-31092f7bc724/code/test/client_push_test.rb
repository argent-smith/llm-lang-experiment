# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "stringio"

# syncbox push against the real server app over HTTP.
class ClientPushTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @dir = File.join(@tmp, "local")
    @data_dir = File.join(@tmp, "data")
    Dir.mkdir(@dir)
    @requests = []
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080)
    server_app = Syncbox::Server::Runner.build_app(config)
    @server = TestHTTPServer.new(lambda { |env|
      @requests << "#{env['REQUEST_METHOD']} #{env['PATH_INFO']}"
      server_app.call(env)
    })
  end

  def teardown
    @server.stop
    FileUtils.remove_entry(@tmp)
  end

  def test_uploads_every_file_under_its_relative_posix_path
    files = {
      "top.txt" => "top", "docs/readme.txt" => "read me", "docs/img/logo.png" => "\x89PNG\x00\xFF".b,
      "empty" => "", ".hidden/.file" => "h", "é/ü ñ.txt" => "unicode",
      "odd/50% #?+&=;.txt" => "needs escaping", "a/b/c/d/e/f" => "deep", "big.bin" => Random.new(1).bytes(3_000_000)
    }
    files.each { |key, body| write_local(key, body) }

    status, out, err = push
    assert_equal 0, status, err
    assert_empty err
    assert_equal files.keys.sort, server_blobs.keys
    files.each do |key, body|
      assert_equal Digest::SHA256.hexdigest(body), server_blobs.fetch(key), key
      assert_equal body, File.binread(File.join(@data_dir, "blobs", key)), key
      assert_includes out, "uploaded #{key}\n"
    end
    assert_match(/^push: #{files.size} uploaded, 0 unchanged$/, out)
  end

  def test_second_push_uploads_nothing
    write_local("a.txt", "a")
    write_local("dir/b.txt", "b")
    assert_equal 0, push.first

    @requests.clear
    status, out, = push
    assert_equal 0, status
    assert_equal ["GET /blobs"], @requests
    assert_equal "push: 0 uploaded, 2 unchanged\n", out
  end

  def test_uploads_only_missing_and_changed_files
    write_local("same.txt", "same")
    write_local("changed.txt", "old")
    write_local("dir/gone-from-server.txt", "x")
    assert_equal 0, push.first
    FileUtils.rm(File.join(@data_dir, "blobs", "dir", "gone-from-server.txt"))
    write_local("changed.txt", "new contents")
    write_local("new/file.txt", "fresh")

    @requests.clear
    status, out, = push
    assert_equal 0, status
    assert_equal ["GET /blobs", "PUT /blobs/changed.txt", "PUT /blobs/dir/gone-from-server.txt", "PUT /blobs/new/file.txt"],
                 @requests
    assert_equal "uploaded changed.txt\nuploaded dir/gone-from-server.txt\nuploaded new/file.txt\n" \
                 "push: 3 uploaded, 1 unchanged\n", out
    assert_equal "new contents", File.read(File.join(@data_dir, "blobs", "changed.txt"))
  end

  # Only the hash decides: a touched but identical file is not sent again,
  # an edit that keeps the size and mtime is.
  def test_compares_by_sha256_not_by_size_or_mtime
    path = write_local("f", "aaaa")
    assert_equal 0, push.first

    File.utime(Time.now + 3600, Time.now + 3600, path)
    @requests.clear
    push
    assert_equal ["GET /blobs"], @requests

    mtime = File.mtime(path)
    File.binwrite(path, "bbbb")
    File.utime(mtime, mtime, path)
    push
    assert_equal "bbbb", File.read(File.join(@data_dir, "blobs", "f"))
  end

  def test_same_contents_under_another_key_is_still_uploaded
    put_on_server("old/name.txt", "contents")
    write_local("new/name.txt", "contents")

    status, out, = push
    assert_equal 0, status
    assert_includes out, "uploaded new/name.txt\n"
    assert_equal %w[new/name.txt old/name.txt], server_blobs.keys
  end

  def test_blobs_only_on_the_server_are_left_alone
    put_on_server("server-only", "keep me")
    write_local("local", "l")

    assert_equal 0, push.first
    assert_equal %w[local server-only], server_blobs.keys
    assert_equal "keep me", File.read(File.join(@data_dir, "blobs", "server-only"))
  end

  def test_empty_directory_pushes_nothing
    Dir.mkdir(File.join(@dir, "empty-subdir"))
    status, out, = push
    assert_equal 0, status
    assert_equal "push: 0 uploaded, 0 unchanged\n", out
    assert_equal ["GET /blobs"], @requests
  end

  def test_symlinks_and_special_files_are_skipped_with_a_warning
    write_local("real/file", "x")
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    File.write(File.join(outside, "secret"), "s")
    File.symlink(outside, File.join(@dir, "dirlink"))
    File.symlink("real/file", File.join(@dir, "filelink"))
    File.mkfifo(File.join(@dir, "fifo"))

    status, _out, err = push
    assert_equal 0, status
    assert_equal ["real/file"], server_blobs.keys
    assert_includes err, "skipping dirlink: symbolic link"
    assert_includes err, "skipping filelink: symbolic link"
    assert_includes err, "skipping fifo: not a regular file"
  end

  def test_names_that_are_not_utf8_are_skipped_with_a_warning
    write_local("ok", "x")
    File.binwrite(File.join(@dir.b, "bad\xFF".b), "y")

    status, _out, err = push
    assert_equal 0, status
    assert_equal ["ok"], server_blobs.keys
    assert_match(/skipping bad.*not valid UTF-8/, err)
  end

  def test_server_url_may_have_a_trailing_slash
    write_local("a", "a")
    status, = push(server: "#{@server.url}/")
    assert_equal 0, status
    assert_equal ["a"], server_blobs.keys
  end

  def test_missing_or_non_directory_dir_fails
    status, _out, err = push(dir: File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_match(/no such directory/, err)

    status, _out, err = push(dir: write_local("file", "x"))
    assert_equal 1, status
    assert_match(/not a directory/, err)
    assert_empty server_blobs
  end

  def test_unreadable_file_fails_with_a_message
    skip "root can read anything" if Process.uid.zero?

    File.chmod(0o000, write_local("secret", "x"))
    status, _out, err = push
    assert_equal 1, status
    assert_equal "syncbox: cannot read secret: Permission denied\n", err
  end

  def test_unreachable_server_fails_fast_with_a_message
    write_local("a", "a")
    port = @server.port
    @server.stop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, out, err = push(server: "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_match(%r{\Asyncbox: cannot reach server http://127\.0\.0\.1:#{port}: Connection refused\n\z}, err)
    assert_empty out
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_server_error_on_upload_fails_with_status_and_message
    write_local("a", "a")
    app = lambda do |env|
      if env["REQUEST_METHOD"] == "GET"
        [200, { "content-type" => "application/json" }, ["[]"]]
      else
        [500, { "content-type" => "text/plain" }, ["disk on fire\n"]]
      end
    end
    TestHTTPServer.open(app) do |broken|
      status, _out, err = push(server: broken.url)
      assert_equal 1, status
      assert_equal "syncbox: server answered PUT a with HTTP 500: disk on fire\n", err
    end
  end

  def test_unexpected_listing_fails_with_a_message
    write_local("a", "a")
    ["not json", '{"key":"a"}', '[{"key":1}]'].each do |body|
      TestHTTPServer.open(->(_env) { [200, { "content-type" => "application/json" }, [body]] }) do |odd|
        status, _out, err = push(server: odd.url)
        assert_equal 1, status, body
        assert_match(%r{unexpected response from server to GET /blobs}, err)
      end
    end
  end

  private

  def push(dir: @dir, server: @server.url)
    out = StringIO.new
    err = StringIO.new
    status = Syncbox::Client::CLI.run(["push", dir, "--server", server], env: {}, out: out, err: err)
    [status, out.string, err.string]
  end

  def write_local(key, body)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    path
  end

  def put_on_server(key, body)
    Net::HTTP.new("127.0.0.1", @server.port).put("/blobs/#{key}", body, "content-type" => "application/octet-stream")
  end

  def server_blobs
    JSON.parse(Net::HTTP.get(URI("#{@server.url}/blobs"))).to_h { |e| [e["key"], e["sha256"]] }
  end
end
