# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "socket"
require "stringio"

# syncbox pull against the real server app over HTTP.
class ClientPullTest < Minitest::Test
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
    FileUtils.chmod_R("u+rwx", @tmp)
    FileUtils.remove_entry(@tmp)
  end

  def test_downloads_every_blob_to_its_relative_posix_path
    blobs = {
      "top.txt" => "top", "docs/readme.txt" => "read me", "docs/img/logo.png" => "\x89PNG\x00\xFF".b,
      "empty" => "", ".hidden/.file" => "h", "é/ü ñ.txt" => "unicode",
      "odd/50% #?+&=;.txt" => "needs escaping", "a/b/c/d/e/f" => "deep", "big.bin" => Random.new(1).bytes(3_000_000)
    }
    blobs.each { |key, body| put_on_server(key, body) }

    status, out, err = pull
    assert_equal 0, status, err
    assert_empty err
    assert_equal blobs.keys.sort, local_files.keys
    blobs.each do |key, body|
      assert_equal body, local_files.fetch(key), key
      assert_includes out, "downloaded #{key}\n"
    end
    assert_match(/^pull: #{blobs.size} downloaded, 0 unchanged$/, out)
  end

  def test_second_pull_downloads_nothing
    put_on_server("a.txt", "a")
    put_on_server("dir/b.txt", "b")
    assert_equal 0, pull.first

    @requests.clear
    status, out, = pull
    assert_equal 0, status
    assert_equal ["GET /blobs"], @requests
    assert_equal "pull: 0 downloaded, 2 unchanged\n", out
  end

  def test_downloads_only_missing_and_changed_files_and_keeps_local_only_ones
    put_on_server("same.txt", "same")
    put_on_server("changed.txt", "new contents")
    put_on_server("dir/missing.txt", "x")
    put_on_server("new/file.txt", "fresh")
    write_local("same.txt", "same")
    write_local("changed.txt", "old")
    write_local("dir/local-only.txt", "mine")
    write_local("local-only.txt", "mine too")

    status, out, = pull
    assert_equal 0, status
    assert_equal ["GET /blobs", "GET /blobs/changed.txt", "GET /blobs/dir/missing.txt", "GET /blobs/new/file.txt"],
                 @requests
    assert_equal "downloaded changed.txt\ndownloaded dir/missing.txt\ndownloaded new/file.txt\n" \
                 "pull: 3 downloaded, 1 unchanged\n", out
    assert_equal({ "changed.txt" => "new contents", "dir/local-only.txt" => "mine", "dir/missing.txt" => "x",
                   "local-only.txt" => "mine too", "new/file.txt" => "fresh", "same.txt" => "same" }, local_files)
  end

  # Only the contents decide: an identical file with another mtime is left
  # alone, a different one of the same size and mtime is replaced.
  def test_compares_by_sha256_not_by_mtime
    put_on_server("f", "aaaa")
    path = write_local("f", "aaaa")
    File.utime(Time.now + 3600, Time.now + 3600, path)
    pull
    assert_equal ["GET /blobs"], @requests

    mtime = File.mtime(path)
    File.binwrite(path, "bbbb")
    File.utime(mtime, mtime, path)
    status, out, = pull
    assert_equal 0, status
    assert_includes out, "downloaded f\n"
    assert_equal "aaaa", File.read(path)
  end

  def test_pull_restores_what_push_uploaded
    source = File.join(@tmp, "source")
    files = { "a.txt" => "a", "nested/dir/b.bin" => Random.new(2).bytes(100_000), "nested/c" => "" }
    files.each do |key, body|
      FileUtils.mkdir_p(File.dirname(File.join(source, key)))
      File.binwrite(File.join(source, key), body)
    end
    assert_equal 0, run_cli("push", source).first

    status, = pull
    assert_equal 0, status
    assert_equal files.sort.to_h, local_files
  end

  def test_replaced_file_keeps_its_permissions
    put_on_server("script.sh", "#!/bin/sh\necho new\n")
    put_on_server("new.txt", "n")
    path = write_local("script.sh", "#!/bin/sh\necho old\n")
    File.chmod(0o750, path)

    assert_equal 0, pull.first
    assert_equal "#!/bin/sh\necho new\n", File.read(path)
    assert_equal 0o750, File.stat(path).mode & 0o7777
    assert_equal 0o666 & ~File.umask, File.stat(File.join(@dir, "new.txt")).mode & 0o7777
  end

  def test_empty_server_downloads_nothing
    write_local("mine", "m")
    status, out, = pull
    assert_equal 0, status
    assert_equal "pull: 0 downloaded, 0 unchanged\n", out
    assert_equal({ "mine" => "m" }, local_files)
  end

  def test_keys_that_would_leave_the_directory_are_skipped_with_a_warning
    victim = File.join(@tmp, "victim")
    File.write(victim, "untouched")
    keys = ["../victim", victim, "a/../../victim", "a//b", "./x", "a/.", "a/", "", "nul\0byte"]
    listing = (keys.map { |k| blob_meta(k, "evil") } + [blob_meta("fine", "ok")])
    serve_fake(listing, { "fine" => "ok" }) do |url|
      status, out, err = pull(server: url)
      assert_equal 0, status, err
      assert_equal "downloaded fine\npull: 1 downloaded, 0 unchanged\n", out
      keys.each { |k| assert_includes err, "skipping #{k.inspect}: not a valid key" }
    end
    assert_equal "untouched", File.read(victim)
    assert_equal({ "fine" => "ok" }, local_files)
    assert_equal %w[local victim], Dir.children(@tmp).reject { |n| n == "data" }.sort
  end

  def test_symlinks_are_neither_followed_nor_replaced
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    File.write(File.join(outside, "file"), "outside")
    File.symlink(outside, File.join(@dir, "dirlink"))
    File.symlink(File.join(outside, "file"), File.join(@dir, "filelink"))
    put_on_server("dirlink/file", "evil")
    put_on_server("dirlink/new", "evil")
    put_on_server("filelink", "evil")
    put_on_server("ok", "ok")

    status, out, err = pull
    assert_equal 0, status, err
    assert_equal "downloaded ok\npull: 1 downloaded, 0 unchanged\n", out
    assert_includes err, "skipping dirlink/file: dirlink is a symbolic link"
    assert_includes err, "skipping dirlink/new: dirlink is a symbolic link"
    assert_includes err, "skipping filelink: symbolic link"
    assert_equal ["file"], Dir.children(outside)
    assert_equal "outside", File.read(File.join(outside, "file"))
    assert File.symlink?(File.join(@dir, "filelink"))
  end

  def test_directory_given_as_a_symlink_is_used
    put_on_server("a/b", "b")
    link = File.join(@tmp, "link")
    File.symlink(@dir, link)
    status, _out, err = pull(dir: link)
    assert_equal 0, status, err
    assert_equal({ "a/b" => "b" }, local_files)
  end

  def test_special_files_are_skipped_with_a_warning
    File.mkfifo(File.join(@dir, "fifo"))
    put_on_server("fifo", "data")
    status, out, err = pull
    assert_equal 0, status
    assert_equal "pull: 0 downloaded, 0 unchanged\n", out
    assert_includes err, "skipping fifo: not a regular file"
    assert File.pipe?(File.join(@dir, "fifo"))
  end

  def test_file_in_the_way_of_a_directory_fails
    write_local("a", "file")
    serve_fake([blob_meta("a/b", "x")], { "a/b" => "x" }) do |url|
      status, _out, err = pull(server: url)
      assert_equal 1, status
      assert_equal "syncbox: cannot write a/b: a is not a directory\n", err
    end
    assert_equal({ "a" => "file" }, local_files)
  end

  def test_directory_where_the_file_goes_fails
    write_local("a/inside", "i")
    serve_fake([blob_meta("a", "x")], { "a" => "x" }) do |url|
      status, _out, err = pull(server: url)
      assert_equal 1, status
      assert_equal "syncbox: cannot write a: it is a directory\n", err
    end
    assert_equal({ "a/inside" => "i" }, local_files)
  end

  def test_missing_or_non_directory_dir_fails_without_contacting_the_server
    status, _out, err = pull(dir: File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_match(/no such directory/, err)

    status, _out, err = pull(dir: write_local("file", "x"))
    assert_equal 1, status
    assert_match(/not a directory/, err)
    assert_empty @requests
  end

  def test_unwritable_directory_fails_with_a_message
    skip "root can write anything" if Process.uid.zero?

    put_on_server("a", "a")
    File.chmod(0o555, @dir)
    status, _out, err = pull
    assert_equal 1, status
    assert_equal "syncbox: cannot write a: Permission denied\n", err
  end

  def test_unreadable_local_file_fails_with_a_message
    skip "root can read anything" if Process.uid.zero?

    put_on_server("secret", "s")
    File.chmod(0o000, write_local("secret", "x"))
    status, _out, err = pull
    assert_equal 1, status
    assert_equal "syncbox: cannot read secret: Permission denied\n", err
  end

  def test_unreachable_server_fails_fast_with_a_message
    port = @server.port
    @server.stop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, out, err = pull(server: "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_match(%r{\Asyncbox: cannot reach server http://127\.0\.0\.1:#{port}: Connection refused\n\z}, err)
    assert_empty out
    assert_empty Dir.children(@dir)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_failed_download_leaves_the_local_file_as_it_was
    write_local("a", "old")
    app = lambda do |env|
      if env["PATH_INFO"] == "/blobs"
        [200, { "content-type" => "application/json" }, [JSON.generate([blob_meta("a", "new")])]]
      else
        [500, { "content-type" => "text/plain" }, ["disk on fire\n"]]
      end
    end
    TestHTTPServer.open(app) do |broken|
      status, out, err = pull(server: broken.url)
      assert_equal 1, status
      assert_equal "syncbox: server answered GET a with HTTP 500: disk on fire\n", err
      assert_empty out
    end
    assert_equal({ "a" => "old" }, local_files)
  end

  def test_blob_gone_from_the_server_fails_with_a_message
    serve_fake([blob_meta("dir/gone", "x")], {}) do |url|
      status, _out, err = pull(server: url)
      assert_equal 1, status
      assert_match(%r{\Asyncbox: server answered GET dir/gone with HTTP 404}, err)
    end
    assert_empty local_files
  end

  def test_connection_lost_mid_download_leaves_no_partial_file
    write_local("a", "old")
    listing = JSON.generate([blob_meta("a", "new contents")])
    with_raw_server(lambda { |path|
      if path == "/blobs"
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{listing.bytesize}\r\n" \
          "connection: close\r\n\r\n#{listing}"
      else
        "HTTP/1.1 200 OK\r\ncontent-length: 1000\r\nconnection: close\r\n\r\nnew con"
      end
    }) do |url|
      status, _out, err = pull(server: url)
      assert_equal 1, status
      assert_match(/\Asyncbox: cannot reach server/, err)
    end
    assert_equal({ "a" => "old" }, local_files)
    assert_equal ["a"], Dir.children(@dir)
  end

  # A local failure while the body streams in (say, a full disk) is reported
  # as such, not as the server being unreachable.
  def test_errors_writing_a_download_are_not_mistaken_for_network_errors
    put_on_server("a", "contents")
    Syncbox::Client::Remote.open(URI(@server.url)) do |remote|
      assert_raises(Errno::ENOSPC) { remote.get("a") { raise Errno::ENOSPC } }
      chunks = +""
      remote.get("a") { |chunk| chunks << chunk } # the connection is still usable
      assert_equal "contents", chunks
    end

    local_dir = Syncbox::Client::LocalDir.new(@dir)
    target = local_dir.target("dir/a")
    error = assert_raises(Syncbox::Client::Error) { local_dir.write(target) { raise Errno::ENOSPC } }
    assert_equal "cannot write dir/a: No space left on device", error.message
    assert_empty Dir.children(File.join(@dir, "dir")), "the staged file is removed"
  end

  def test_unexpected_listing_fails_with_a_message
    ["not json", '{"key":"a"}', '[{"key":1}]', '[{"key":"a"}]'].each do |body|
      TestHTTPServer.open(->(_env) { [200, { "content-type" => "application/json" }, [body]] }) do |odd|
        status, _out, err = pull(server: odd.url)
        assert_equal 1, status, body
        assert_match(%r{unexpected response from server to GET /blobs}, err)
      end
    end
    assert_empty Dir.children(@dir)
  end

  def test_server_url_may_have_a_trailing_slash_or_a_path_prefix
    put_on_server("a", "a")
    status, = pull(server: "#{@server.url}/")
    assert_equal 0, status
    assert_equal({ "a" => "a" }, local_files)

    FileUtils.rm(File.join(@dir, "a"))
    server_app = Syncbox::Server::Runner.build_app(Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080))
    paths = []
    prefixed_app = lambda do |env|
      paths << env["PATH_INFO"]
      server_app.call(env.merge("PATH_INFO" => env["PATH_INFO"].delete_prefix("/prefix")))
    end
    TestHTTPServer.open(prefixed_app) do |prefixed|
      status, _out, err = pull(server: "#{prefixed.url}/prefix")
      assert_equal 0, status, err
    end
    assert_equal ["/prefix/blobs", "/prefix/blobs/a"], paths
    assert_equal({ "a" => "a" }, local_files)
  end

  private

  def pull(dir: @dir, server: @server.url)
    run_cli("pull", dir, server: server)
  end

  def run_cli(command, dir, server: @server.url)
    out = StringIO.new
    err = StringIO.new
    status = Syncbox::Client::CLI.run([command, dir, "--server", server], env: {}, out: out, err: err)
    [status, out.string, err.string]
  end

  def write_local(key, body)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    path
  end

  # Every regular file under the local dir: {key => contents}.
  def local_files
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).sort.filter_map do |rel|
      path = File.join(@dir, rel)
      [rel, File.binread(path)] if File.file?(path) && !File.symlink?(path)
    end.to_h
  end

  def put_on_server(key, body)
    response = Net::HTTP.new("127.0.0.1", @server.port)
                        .put("/blobs/#{Syncbox::Client::Remote.escape_key(key)}", body, "content-type" => "application/octet-stream")
    assert_equal "201", response.code, key
    @requests.clear
  end

  def blob_meta(key, body)
    { "key" => key, "size" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body),
      "modified_at" => "2026-01-01T00:00:00Z" }
  end

  # A server whose listing and blobs ({key => body}) are given as they are,
  # not as the real server would store them.
  def serve_fake(listing, bodies, &)
    json = JSON.generate(listing)
    app = lambda do |env|
      if env["PATH_INFO"] == "/blobs"
        [200, { "content-type" => "application/json" }, [json]]
      else
        key = URI.decode_uri_component(env["PATH_INFO"].delete_prefix("/blobs/"))
        bodies.key?(key) ? [200, {}, [bodies[key]]] : [404, {}, ["not found\n"]]
      end
    end
    TestHTTPServer.open(app) { |server| yield server.url }
  end

  # A bare TCP server answering each request with respond.(path), for
  # responses Puma wouldn't send.
  def with_raw_server(respond)
    listener = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = listener.accept
        path = client.gets.to_s.split[1]
        nil until ["\r\n", "\n", nil].include?(client.gets)
        client.write(respond.(path))
        client.close
      end
    rescue IOError
      nil
    end
    yield "http://127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
    thread&.join(1)
    thread&.kill
  end
end
