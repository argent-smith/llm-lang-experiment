# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "stringio"

# syncbox status against the real server app over HTTP.
class ClientStatusTest < Minitest::Test
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

  def test_local_only_file_would_be_uploaded
    write_local("docs/new.txt", "new")
    status, out, err = run_status
    assert_equal 0, status, err
    assert_empty err
    assert_equal "upload    new      docs/new.txt\nstatus: 1 to upload, 0 to download, 0 unchanged\n", out
  end

  def test_server_only_blob_would_be_downloaded
    put_on_server("docs/remote.txt", "remote")
    status, out, err = run_status
    assert_equal 0, status, err
    assert_empty err
    assert_equal "download  new      docs/remote.txt\nstatus: 0 to upload, 1 to download, 0 unchanged\n", out
  end

  # push would upload it and pull would download it: both are shown.
  def test_file_with_other_contents_is_shown_both_ways
    put_on_server("f.txt", "server version")
    write_local("f.txt", "local version")
    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal "upload    changed  f.txt\ndownload  changed  f.txt\n" \
                 "status: 1 to upload, 1 to download, 0 unchanged\n", out
  end

  def test_identical_sides_are_reported_in_sync
    { "a.txt" => "a", "dir/b.txt" => "b", "empty" => "" }.each do |key, body|
      put_on_server(key, body)
      write_local(key, body)
    end
    status, out, err = run_status
    assert_equal 0, status, err
    assert_empty err
    assert_equal "status: in sync, 3 unchanged\n", out
  end

  def test_empty_directory_and_empty_server_are_in_sync
    status, out, = run_status
    assert_equal 0, status
    assert_equal "status: in sync, 0 unchanged\n", out
  end

  def test_mixed_report_lists_uploads_then_downloads_sorted_by_key
    put_on_server("same.txt", "same")
    put_on_server("changed.txt", "server")
    put_on_server("z/server-only.txt", "s")
    put_on_server("a/server-only.txt", "s")
    write_local("same.txt", "same")
    write_local("changed.txt", "local")
    write_local("y/local-only.txt", "l")
    write_local("b/local-only.txt", "l")

    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal <<~OUT, out
      upload    new      b/local-only.txt
      upload    changed  changed.txt
      upload    new      y/local-only.txt
      download  new      a/server-only.txt
      download  changed  changed.txt
      download  new      z/server-only.txt
      status: 3 to upload, 3 to download, 1 unchanged
    OUT
  end

  def test_keys_are_relative_posix_paths
    files = { "é/ü ñ.txt" => "unicode", "odd/50% #?+&=;.txt" => "escaping", ".hidden/.file" => "h", "a/b/c/d/e/f" => "deep" }
    files.each { |key, body| write_local(key, body) }
    files.each_key { |key| put_on_server("remote/#{key}", "r") }

    status, out, err = run_status
    assert_equal 0, status, err
    files.each_key do |key|
      assert_includes out, "upload    new      #{key}\n"
      assert_includes out, "download  new      remote/#{key}\n"
    end
  end

  # Only the contents decide: an identical file with another mtime is
  # unchanged, a different one of the same size and mtime is not.
  def test_compares_by_sha256_not_by_size_or_mtime
    put_on_server("f", "aaaa")
    path = write_local("f", "aaaa")
    File.utime(Time.now + 3600, Time.now + 3600, path)
    assert_equal "status: in sync, 1 unchanged\n", run_status[1]

    mtime = File.mtime(path)
    File.binwrite(path, "bbbb")
    File.utime(mtime, mtime, path)
    assert_equal "upload    changed  f\ndownload  changed  f\nstatus: 1 to upload, 1 to download, 0 unchanged\n",
                 run_status[1]
  end

  def test_changes_nothing_on_either_side
    put_on_server("same.txt", "same")
    put_on_server("changed.txt", "server")
    put_on_server("dir/server-only.txt", "s")
    write_local("same.txt", "same")
    write_local("changed.txt", "local")
    write_local("dir/local-only.txt", "l")
    File.chmod(0o640, write_local("mode.sh", "m"))
    local_before = snapshot(@dir)
    server_before = snapshot(@data_dir)
    listing_before = server_listing

    3.times do
      status, out, err = run_status
      assert_equal 0, status, err
      assert_match(/^status: 3 to upload, 2 to download, 1 unchanged$/, out)
    end

    assert_equal ["GET /blobs"] * 3, @requests
    assert_equal local_before, snapshot(@dir)
    assert_equal server_before, snapshot(@data_dir)
    assert_equal listing_before, server_listing
  end

  def test_works_on_a_read_only_directory
    skip "root can write anything" if Process.uid.zero?

    write_local("dir/local-only.txt", "l")
    put_on_server("dir/server-only.txt", "s")
    put_on_server("new-dir/x", "x")
    FileUtils.chmod_R("a-w", @dir)

    status, out, err = run_status
    assert_equal 0, status, err
    assert_empty err
    assert_equal "upload    new      dir/local-only.txt\ndownload  new      dir/server-only.txt\n" \
                 "download  new      new-dir/x\nstatus: 1 to upload, 2 to download, 0 unchanged\n", out
  end

  # status is a dry run of push and pull: they do exactly what it showed.
  def test_push_and_pull_then_do_what_status_showed
    put_on_server("same.txt", "same")
    put_on_server("changed.txt", "server")
    put_on_server("dir/server-only.txt", "s")
    write_local("same.txt", "same")
    write_local("changed.txt", "local")
    write_local("dir/local-only.txt", "l")

    out = run_status[1]
    uploads = out.scan(/^upload +\w+ +(.+)$/).flatten
    downloads = out.scan(/^download +\w+ +(.+)$/).flatten

    pull_out = run_cli("pull")[1]
    assert_equal downloads, pull_out.scan(/^downloaded (.+)$/).flatten
    write_local("changed.txt", "local") # pull replaced it; push the local version
    push_out = run_cli("push")[1]
    assert_equal uploads, push_out.scan(/^uploaded (.+)$/).flatten

    assert_equal "status: in sync, 4 unchanged\n", run_status[1]
  end

  def test_skips_what_push_and_pull_would_skip_with_a_warning
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    File.write(File.join(outside, "file"), "outside")
    File.symlink(outside, File.join(@dir, "dirlink"))
    File.symlink(File.join(outside, "file"), File.join(@dir, "filelink"))
    File.mkfifo(File.join(@dir, "fifo"))
    File.binwrite(File.join(@dir.b, "bad\xFF".b), "x")
    write_local("ok", "ok")
    listing = ["../victim", "/abs", "a//b", "dirlink/file", "filelink", "fifo", "fine"].map { |k| blob_meta(k, "evil") }

    serve_fake(listing) do |url|
      status, out, err = run_status(server: url)
      assert_equal 0, status, err
      assert_equal "upload    new      ok\ndownload  new      fine\nstatus: 1 to upload, 1 to download, 0 unchanged\n", out
      ["skipping dirlink: symbolic link", "skipping filelink: symbolic link", "skipping fifo: not a regular file",
       "skipping bad�: name is not valid UTF-8", 'skipping "../victim": not a valid key',
       'skipping "/abs": not a valid key', 'skipping "a//b": not a valid key',
       "skipping dirlink/file: dirlink is a symbolic link"].each do |warning|
        assert_includes err, "syncbox: #{warning}\n"
      end
    end
    assert_equal ["file"], Dir.children(outside)
    assert File.pipe?(File.join(@dir, "fifo"))
  end

  # pull would fail on such keys; status says so and goes on.
  def test_keys_blocked_by_a_file_or_directory_are_reported
    write_local("a", "file")
    write_local("d/inside", "i")
    serve_fake([blob_meta("a/b", "x"), blob_meta("d", "x"), blob_meta("e", "x")]) do |url|
      status, out, err = run_status(server: url)
      assert_equal 0, status, err
      assert_equal "syncbox: cannot download a/b: a is not a directory\n" \
                   "syncbox: cannot download d: it is a directory\n", err
      assert_equal "upload    new      a\nupload    new      d/inside\ndownload  new      e\n" \
                   "status: 2 to upload, 1 to download, 0 unchanged\n", out
    end
    assert_equal({ "a" => "file", "d/inside" => "i" }, local_files)
  end

  def test_missing_or_non_directory_dir_fails_without_contacting_the_server
    status, out, err = run_status(dir: File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_match(/no such directory/, err)
    assert_empty out

    status, _out, err = run_status(dir: write_local("file", "x"))
    assert_equal 1, status
    assert_match(/not a directory/, err)
    assert_empty @requests
  end

  def test_unreachable_server_fails_fast_with_a_message
    write_local("a", "a")
    port = @server.port
    @server.stop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, out, err = run_status(server: "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_equal "syncbox: cannot reach server http://127.0.0.1:#{port}: Connection refused\n", err
    assert_empty out
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_server_error_on_listing_fails_with_a_message
    TestHTTPServer.open(->(_env) { [500, { "content-type" => "text/plain" }, ["disk on fire\n"]] }) do |broken|
      status, out, err = run_status(server: broken.url)
      assert_equal 1, status
      assert_equal "syncbox: server answered GET /blobs with HTTP 500: disk on fire\n", err
      assert_empty out
    end
  end

  def test_unexpected_listing_fails_with_a_message
    ["not json", '{"key":"a"}', '[{"key":1}]', '[{"key":"a"}]'].each do |body|
      TestHTTPServer.open(->(_env) { [200, { "content-type" => "application/json" }, [body]] }) do |odd|
        status, _out, err = run_status(server: odd.url)
        assert_equal 1, status, body
        assert_match(%r{unexpected response from server to GET /blobs}, err)
      end
    end
  end

  def test_unreadable_local_file_fails_with_a_message
    skip "root can read anything" if Process.uid.zero?

    File.chmod(0o000, write_local("secret", "x"))
    status, _out, err = run_status
    assert_equal 1, status
    assert_equal "syncbox: cannot read secret: Permission denied\n", err
  end

  def test_server_url_may_have_a_trailing_slash
    put_on_server("a", "a")
    status, out, = run_status(server: "#{@server.url}/")
    assert_equal 0, status
    assert_equal "download  new      a\nstatus: 0 to upload, 1 to download, 0 unchanged\n", out
  end

  private

  def run_status(dir: @dir, server: @server.url)
    run_cli("status", dir: dir, server: server)
  end

  def run_cli(command, dir: @dir, server: @server.url)
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

  # Everything under root that a write could change: each entry's type,
  # mode, mtime and contents.
  def snapshot(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.to_h do |rel|
      stat = File.lstat(File.join(root, rel))
      contents = File.binread(File.join(root, rel)) if stat.file?
      [rel, [stat.ftype, stat.mode, stat.mtime, stat.size, contents]]
    end
  end

  def server_listing
    JSON.parse(Net::HTTP.get(URI("#{@server.url}/blobs"))).tap { @requests.clear }
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

  # A server answering GET /blobs with the given listing as it is, and
  # 404 to anything else; status must send it nothing but GET /blobs.
  def serve_fake(listing)
    json = JSON.generate(listing)
    requests = []
    app = lambda do |env|
      requests << "#{env['REQUEST_METHOD']} #{env['PATH_INFO']}"
      next [200, { "content-type" => "application/json" }, [json]] if env["PATH_INFO"] == "/blobs"

      [404, {}, ["not found\n"]]
    end
    TestHTTPServer.open(app) { |server| yield server.url }
    assert_equal ["GET /blobs"], requests
  end
end
