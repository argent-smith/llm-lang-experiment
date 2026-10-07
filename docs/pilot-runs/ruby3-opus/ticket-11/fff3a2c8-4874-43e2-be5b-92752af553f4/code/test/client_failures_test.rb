# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "socket"
require "stringio"

# What every client command does when things go wrong ("Коды возврата и
# ошибки" in the spec): an unreachable or stuck server fails the command with
# a message on stderr and exit status 1, without hanging; a file that fails
# doesn't stop the others, and all failures are reported at the end.
class ClientFailuresTest < Minitest::Test
  COMMANDS = %w[push pull sync status].freeze
  # Short limits, so that timeouts are quick to test.
  TIMEOUTS = Syncbox::Client::Remote::Timeouts.new(open: 1, read: 0.5, write: 0.5)
  STATE_FILE = ".syncbox-state.json"

  def setup
    @tmp = Dir.mktmpdir
    @dir = File.join(@tmp, "local")
    @data_dir = File.join(@tmp, "data")
    Dir.mkdir(@dir)
    @server_app = Syncbox::Server::Runner.build_app(Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080))
  end

  def teardown
    FileUtils.chmod_R("u+rwx", @tmp)
    FileUtils.remove_entry(@tmp)
  end

  # The server is unreachable

  def test_every_network_operation_has_a_time_limit_by_default
    http = Syncbox::Client::Remote.new(URI("http://127.0.0.1:1")).instance_variable_get(:@http)
    assert_equal [10, 60, 60], [http.open_timeout, http.read_timeout, http.write_timeout]
    assert_equal 0, http.max_retries
  end

  def test_connection_refused_fails_every_command_fast_with_a_message
    write_local("a", "a")
    url = "http://127.0.0.1:#{unused_port}"
    COMMANDS.each do |command|
      status, out, err, elapsed = run_client(command, url)
      assert_equal 1, status, command
      assert_equal "syncbox: cannot reach server #{url}: Connection refused\n", err, command
      assert_empty out, command
      assert_operator elapsed, :<, 5, command
    end
    assert_equal({ "a" => "a" }, local_files)
  end

  def test_unresolvable_host_name_fails_every_command_with_a_message
    url = "http://syncbox-test.invalid:8080"
    COMMANDS.each do |command|
      status, out, err, elapsed = run_client(command, url)
      assert_equal 1, status, command
      # Without a DNS server to say no, the lookup runs into the time limit.
      assert_match(/\Asyncbox: cannot reach server #{Regexp.escape(url)}: (cannot resolve host name syncbox-test\.invalid: .+|connection timed out after 1 second)\n\z/,
                   err, command)
      assert_empty out, command
      assert_operator elapsed, :<, 5, command
    end
  end

  def test_connection_that_cannot_be_established_in_time_fails_every_command_with_a_message
    with_unanswered_connections do |url|
      COMMANDS.each do |command|
        status, out, err, elapsed = run_client(command, url)
        assert_equal 1, status, command
        assert_equal "syncbox: cannot reach server #{url}: connection timed out after 1 second\n", err, command
        assert_empty out, command
        assert_operator elapsed, :<, 5, command
      end
    end
  end

  def test_server_that_never_answers_fails_every_command_with_a_message
    write_local("a", "a")
    with_silent_server do |url|
      COMMANDS.each do |command|
        status, out, err, elapsed = run_client(command, url)
        assert_equal 1, status, command
        assert_equal "syncbox: no answer from server #{url} to GET /blobs within 0.5 seconds\n", err, command
        assert_empty out, command
        assert_operator elapsed, :<, 5, command
      end
    end
    assert_equal({ "a" => "a" }, local_files)
  end

  # Partial failures

  def test_push_goes_on_after_a_server_error_and_reports_it
    files = { "a.txt" => "a", "b.txt" => "b", "c/d.txt" => "d" }
    files.each { |key, body| write_local(key, body) }
    serve("PUT /blobs/b.txt" => 500) do |url|
      status, out, err = run_client("push", url)
      assert_equal 1, status
      assert_equal "uploaded a.txt\nuploaded c/d.txt\npush: 2 uploaded, 0 unchanged, 1 failed\n", out
      assert_equal "syncbox: push failed for 1 file:\n  server answered PUT b.txt with HTTP 500: disk on fire\n", err

      # Once the server is fine again, the next push uploads just what is missing.
      status, out, = run_client("push", url, failing: false)
      assert_equal 0, status
      assert_equal "uploaded b.txt\npush: 1 uploaded, 2 unchanged\n", out
    end
    assert_equal files, server_files
  end

  def test_push_goes_on_after_a_request_times_out
    %w[a slow z].each { |key| write_local(key, key) }
    serve("PUT /blobs/slow" => :hang) do |url|
      status, out, err, elapsed = run_client("push", url)
      assert_equal 1, status
      assert_equal "uploaded a\nuploaded z\npush: 2 uploaded, 0 unchanged, 1 failed\n", out
      assert_equal "syncbox: push failed for 1 file:\n  no answer from server #{url} to PUT slow within 0.5 seconds\n", err
      assert_operator elapsed, :<, 5
    end
    assert_equal({ "a" => "a", "z" => "z" }, server_files)
  end

  def test_push_goes_on_after_local_files_that_cannot_be_read
    skip "root can read anything" if Process.uid.zero?

    write_local("a", "a")
    File.chmod(0o000, write_local("secret", "s"))
    write_local("private/x", "x")
    File.chmod(0o000, File.join(@dir, "private"))
    write_local("z", "z")
    serve do |url|
      status, out, err = run_client("push", url)
      assert_equal 1, status
      assert_equal "uploaded a\nuploaded z\npush: 2 uploaded, 0 unchanged, 2 failed\n", out
      assert_equal "syncbox: push failed for 2 files:\n  cannot read directory private: Permission denied\n" \
                   "  cannot read secret: Permission denied\n", err
    end
    assert_equal({ "a" => "a", "z" => "z" }, server_files)
  end

  def test_pull_goes_on_after_a_failed_download_and_reports_it
    put_on_server("a" => "a", "b" => "new b", "c/d" => "d")
    write_local("b", "old b")
    serve("GET /blobs/b" => 500) do |url|
      status, out, err = run_client("pull", url)
      assert_equal 1, status
      assert_equal "downloaded a\ndownloaded c/d\npull: 2 downloaded, 0 unchanged, 1 failed\n", out
      assert_equal "syncbox: pull failed for 1 file:\n  server answered GET b with HTTP 500: disk on fire\n", err
    end
    assert_equal({ "a" => "a", "b" => "old b", "c/d" => "d" }, local_files)
  end

  def test_pull_reports_every_kind_of_failure_together
    write_local("x", "a file where a directory should be")
    listing = %w[a cut gone slow x/y z].map { |key| blob_meta(key, "#{key} contents") }
    json = JSON.generate(listing)
    with_raw_server(lambda { |path|
      case path
      when "/blobs" then response(200, json)
      when "/blobs/gone" then response(404, "not found\n")
      # The connection drops before the whole body has arrived.
      when "/blobs/cut" then "HTTP/1.1 200 OK\r\ncontent-length: 1000\r\nconnection: close\r\n\r\ncut con"
      when "/blobs/slow" then sleep(TIMEOUTS.read * 3) && nil
      else response(200, "#{path.delete_prefix('/blobs/')} contents")
      end
    }) do |url|
      status, out, err, elapsed = run_client("pull", url)
      assert_equal 1, status
      assert_equal "downloaded a\ndownloaded z\npull: 2 downloaded, 0 unchanged, 4 failed\n", out
      assert_equal "syncbox: pull failed for 4 files:\n" \
                   "  connection to server #{url} closed during GET cut\n" \
                   "  server answered GET gone with HTTP 404: not found\n" \
                   "  no answer from server #{url} to GET slow within 0.5 seconds\n" \
                   "  cannot write x/y: x is not a directory\n", err
      assert_operator elapsed, :<, 5
    end
    assert_equal({ "a" => "a contents", "x" => "a file where a directory should be", "z" => "z contents" },
                 local_files)
    assert_equal %w[a x z], Dir.children(@dir).sort, "no staging files are left behind"
  end

  def test_sync_goes_on_after_failed_transfers_and_catches_up_later
    write_local("up-fail", "u1")
    write_local("up-ok", "u2")
    put_on_server("down-fail" => "d1", "down-ok" => "d2")
    serve("GET /blobs/down-fail" => 503, "PUT /blobs/up-fail" => 500) do |url|
      status, out, err = run_client("sync", url)
      assert_equal 1, status
      assert_equal "downloaded down-ok\nuploaded up-ok\n" \
                   "sync: 1 uploaded, 1 downloaded, 0 unchanged, 0 conflicts, 2 failed\n", out
      assert_equal "syncbox: sync failed for 2 files:\n  server answered GET down-fail with HTTP 503: disk on fire\n" \
                   "  server answered PUT up-fail with HTTP 500: disk on fire\n", err
      # What got synced is recorded; what failed is not.
      assert_equal %w[down-ok up-ok], JSON.parse(File.read(File.join(@dir, STATE_FILE)))["servers"].values.first.keys

      status, out, = run_client("sync", url, failing: false)
      assert_equal 0, status
      assert_equal "downloaded down-fail\nuploaded up-fail\n" \
                   "sync: 1 uploaded, 1 downloaded, 2 unchanged, 0 conflicts\n", out
    end
    expected = { "down-fail" => "d1", "down-ok" => "d2", "up-fail" => "u1", "up-ok" => "u2" }
    assert_equal expected, server_files
    assert_equal expected, local_files.except(STATE_FILE)
  end

  # Files in a directory that can't be listed may exist all the same: sync
  # must not take them for missing and download the server's copies over them.
  def test_sync_leaves_alone_what_it_cannot_read
    skip "root can read anything" if Process.uid.zero?

    write_local("private/x", "local x")
    File.chmod(0o300, File.join(@dir, "private")) # can write and enter, can't list
    write_local("ok", "ok")
    put_on_server("private/x" => "server x", "private/new" => "new")
    serve do |url|
      status, out, err = run_client("sync", url)
      assert_equal 1, status
      assert_equal "uploaded ok\nsync: 1 uploaded, 0 downloaded, 0 unchanged, 0 conflicts, 1 failed\n", out
      assert_equal "syncbox: sync failed for 1 file:\n  cannot read directory private: Permission denied\n", err
    end
    assert_equal "local x", File.read(File.join(@dir, "private", "x"))
    refute File.exist?(File.join(@dir, "private", "new"))
    assert_equal({ "ok" => "ok", "private/new" => "new", "private/x" => "server x" }, server_files)
  end

  def test_status_goes_on_after_a_file_that_cannot_be_read
    skip "root can read anything" if Process.uid.zero?

    write_local("a", "a")
    File.chmod(0o000, write_local("secret", "s"))
    put_on_server("b" => "b", "secret" => "server secret")
    serve do |url|
      status, out, err = run_client("status", url)
      assert_equal 1, status
      assert_equal "upload    new      a\ndownload  new      b\n" \
                   "status: 1 to upload, 1 to download, 0 unchanged, 1 failed\n", out
      assert_equal "syncbox: status failed for 1 file:\n  cannot read secret: Permission denied\n", err
    end
  end

  # A server gone after the listing: each request is a network error of its
  # own, so each file is tried and reported, and the command doesn't hang.
  def test_every_file_is_reported_when_the_server_goes_away_part_way
    write_local("a", "a")
    expected = {
      "push" => ["push: 0 uploaded, 0 unchanged, 1 failed\n", ["PUT a"]],
      "pull" => ["pull: 0 downloaded, 0 unchanged, 1 failed\n", ["GET b"]],
      "sync" => ["sync: 0 uploaded, 0 downloaded, 0 unchanged, 0 conflicts, 2 failed\n", ["PUT a", "GET b"]]
    }
    expected.each do |command, (summary, requests)|
      with_server_going_away([blob_meta("b", "b")]) do |url|
        status, out, err, elapsed = run_client(command, url)
        assert_equal 1, status, command
        assert_equal summary, out
        assert_equal "syncbox: #{command} failed for #{requests.size} file#{'s' if requests.size > 1}:\n" +
                     requests.map { |what| "  cannot reach server #{url} for #{what}: Connection refused\n" }.join, err
        assert_operator elapsed, :<, 5, command
      end
    end
    assert_equal({ "a" => "a" }, local_files)
  end

  private

  def run_client(command, url, dir: @dir, failing: true)
    @failing_enabled = failing
    out = StringIO.new
    err = StringIO.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = Syncbox::Client::CLI.run([command, dir, "--server", url], env: {}, out: out, err: err, timeouts: TIMEOUTS)
    [status, out.string, err.string, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  # The real server, except that the requests in failing ("PUT /blobs/b")
  # get the error status given, or with :hang no answer in time, while
  # run_client's failing: is true.
  def serve(failing = {})
    app = lambda do |env|
      failure = failing["#{env['REQUEST_METHOD']} #{env['PATH_INFO']}"] if @failing_enabled
      if failure == :hang
        sleep(TIMEOUTS.read * 3)
        [500, { "content-type" => "text/plain" }, ["too late\n"]]
      elsif failure
        [failure, { "content-type" => "text/plain" }, ["disk on fire\n"]]
      else
        @server_app.call(env)
      end
    end
    TestHTTPServer.open(app) { |server| yield server.url }
  end

  # A server answering each request with whatever respond returns for its
  # path (nothing if nil), one request per connection.
  def with_raw_server(respond)
    listener = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        Thread.new(listener.accept) do |client|
          path = client.gets.to_s.split[1]
          nil until ["\r\n", "\n", nil].include?(client.gets)
          answer = respond.call(path)
          client.write(answer) if answer
        rescue IOError, SystemCallError
          nil
        ensure
          client.close
        end
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

  def response(code, body)
    "HTTP/1.1 #{code} X\r\ncontent-type: text/plain\r\ncontent-length: #{body.bytesize}\r\nconnection: close\r\n\r\n#{body}"
  end

  # Accepts connections, but never answers.
  def with_silent_server
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = []
    thread = Thread.new do
      loop { accepted << listener.accept }
    rescue IOError
      nil
    end
    yield "http://127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
    thread&.join(1)
    thread&.kill
    accepted&.each(&:close)
  end

  # Answers GET /blobs with listing and stops listening before the answer is
  # out, so that every later connection is refused.
  def with_server_going_away(listing)
    listener = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{listener.addr[1]}"
    thread = Thread.new do
      client = listener.accept
      nil until ["\r\n", "\n", nil].include?(client.gets)
      listener.close
      json = JSON.generate(listing)
      client.write("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{json.bytesize}\r\n" \
                   "connection: close\r\n\r\n#{json}")
      client.close
    end
    yield url
  ensure
    thread&.join(1)
    thread&.kill
    listener.close unless listener.nil? || listener.closed?
  end

  # A listening socket whose queue of connections is full, as it is never
  # accepted from: the kernel drops further connection attempts unanswered.
  def with_unanswered_connections
    listener = Socket.new(:INET, :STREAM)
    listener.bind(Addrinfo.tcp("127.0.0.1", 0))
    listener.listen(0)
    fillers = []
    until fillers.size > 8
      socket = Socket.new(:INET, :STREAM)
      fillers << socket
      begin
        socket.connect_nonblock(listener.local_address)
      rescue IO::WaitWritable
        break unless socket.wait_writable(0.2)
      end
    end
    skip "could not fill the listen queue" if fillers.size > 8
    yield "http://127.0.0.1:#{listener.local_address.ip_port}"
  ensure
    fillers&.each(&:close)
    listener&.close
  end

  def unused_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def blob_meta(key, body)
    { "key" => key, "size" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body),
      "modified_at" => "2026-01-01T00:00:00Z" }
  end

  def write_local(key, body)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    path
  end

  def put_on_server(files)
    TestHTTPServer.open(@server_app) do |server|
      http = Net::HTTP.new("127.0.0.1", server.port)
      files.each do |key, body|
        assert_equal "201", http.put("/blobs/#{key}", body, "content-type" => "application/octet-stream").code
      end
    end
  end

  def local_files
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).reject { |rel| File.directory?(File.join(@dir, rel)) }.sort
       .to_h { |rel| [rel, File.binread(File.join(@dir, rel))] }
  end

  def server_files
    blobs = File.join(@data_dir, "blobs")
    Dir.glob("**/*", base: blobs).reject { |rel| File.directory?(File.join(blobs, rel)) }.sort
       .to_h { |rel| [rel, File.binread(File.join(blobs, rel))] }
  end
end
