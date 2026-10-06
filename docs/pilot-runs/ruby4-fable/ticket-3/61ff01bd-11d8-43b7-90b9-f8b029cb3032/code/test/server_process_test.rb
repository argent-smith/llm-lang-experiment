# frozen_string_literal: true

require "test_helper"
require "net/http"
require "socket"
require "timeout"
require "open3"
require "time"
require "digest"

# Boots the real executable (bin/syncbox-server) as a child process and talks
# to it over HTTP — the same surface the external acceptance checks use.
class ServerProcessTest < Minitest::Test
  include TestHelpers

  SERVER_BIN = File.join(ROOT, "bin", "syncbox-server")
  BOOT_TIMEOUT = 15

  def test_serves_healthz_via_flags
    with_tmpdir do |dir|
      data_dir = File.join(dir, "store")
      port = free_port

      with_server(%W[--data-dir #{data_dir} --port #{port}]) do
        response = wait_for_healthz(port)
        assert_equal "200", response.code
        assert_equal({ "status" => "ok" }, JSON.parse(response.body))
        assert File.directory?(data_dir), "data dir should be created on boot"
      end
    end
  end

  def test_serves_healthz_via_environment_variables
    with_tmpdir do |dir|
      port = free_port
      env = { "SYNCBOX_DATA_DIR" => dir, "SYNCBOX_PORT" => port.to_s }

      with_server([], env: env) do
        assert_equal "200", wait_for_healthz(port).code
      end
    end
  end

  def test_shuts_down_cleanly_on_sigterm
    with_tmpdir do |dir|
      port = free_port
      pid = spawn_server(%W[--data-dir #{dir} --port #{port}])
      wait_for_healthz(port)

      Process.kill("TERM", pid)
      _, status = Timeout.timeout(BOOT_TIMEOUT) { Process.wait2(pid) }
      assert status.exited?, "server should exit after SIGTERM (status: #{status.inspect})"
      assert_equal 0, status.exitstatus
    end
  end

  # Contract check through the real HTTP stack: every operation on /blobs and
  # /blobs/{key} answers with a status listed for it in syncbox-openapi.yaml,
  # including for garbage keys, and the server never answers 5xx.
  def test_blob_endpoints_answer_within_the_openapi_contract
    with_tmpdir do |dir|
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)

        Net::HTTP.start("127.0.0.1", port) do |http|
          response = http.get("/blobs")
          assert_equal "200", response.code
          assert_equal [], JSON.parse(response.body)

          put = Net::HTTP::Put.new("/blobs/0", "content-type" => "application/octet-stream")
          put.body = "zero"
          response = http.request(put)
          assert_equal "201", response.code
          assert_equal({ "key" => "0", "sha256" => Digest::SHA256.hexdigest("zero"), "size" => 4 },
                       JSON.parse(response.body))

          response = http.get("/blobs")
          assert_equal "200", response.code
          assert_equal ["0"], JSON.parse(response.body).map { |m| m["key"] }

          response = http.get("/blobs/0")
          assert_equal "200", response.code
          assert_equal "zero", response.body

          assert_equal "204", http.delete("/blobs/0").code
          assert_equal "404", http.get("/blobs/0").code
        end

        # Raw sockets so that no client-side URI normalisation hides garbage.
        raw_paths = ["/blobs/", "/blobs//", "/blobs/../x", "/blobs/%2e%2e/x", "/blobs/..%2Fx", "/blobs/%00",
                     "/blobs/%ED%A0%80", "/blobs/%FF", "/blobs/%2F", "/blobs/#{'x' * 300}", "/blobs/a/./b"]
        raw_paths.each do |path|
          status = raw_status(port, "PUT", path, body: "x")
          assert_equal 400, status, "PUT #{path}"
          status = raw_status(port, "GET", path)
          assert_includes [400, 404], status, "GET #{path}"
          status = raw_status(port, "DELETE", path)
          assert_includes [400, 404], status, "DELETE #{path}"
        end
        # Malformed percent escapes: Puma may reject them itself; either way the
        # answer must come from the schema (201 or 400 for PUT) and not be 5xx.
        ["/blobs/50%zz", "/blobs/%", "/blobs/%2", "/blobs/a%G1"].each do |path|
          assert_includes [201, 400], raw_status(port, "PUT", path, body: "x"), "PUT #{path}"
          assert_includes [200, 400, 404], raw_status(port, "GET", path), "GET #{path}"
        end

        assert_equal 200, raw_status(port, "GET", "/blobs")
        assert_equal 200, raw_status(port, "GET", "/healthz"), "server still healthy after garbage"
      end
    end
  end

  # GET /blobs through the real HTTP stack: nested and percent-encoded keys
  # come back as POSIX paths, and every element conforms to BlobMeta in
  # syncbox-openapi.yaml.
  def test_list_blobs_over_http_conforms_to_blob_meta_schema
    with_tmpdir do |dir|
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)

        Net::HTTP.start("127.0.0.1", port) do |http|
          { "docs/readme.txt" => "hello", "docs/img/logo.png" => "\x89PNG".b, "sp%20ace/%C3%BC.txt" => "" }
            .each do |raw_key, body|
            put = Net::HTTP::Put.new("/blobs/#{raw_key}", "content-type" => "application/octet-stream")
            put.body = body
            assert_equal "201", http.request(put).code, raw_key
          end

          response = http.get("/blobs")
          assert_equal "200", response.code
          assert_equal "application/json", response["content-type"]

          list = JSON.parse(response.body)
          assert_equal ["docs/img/logo.png", "docs/readme.txt", "sp ace/ü.txt"], list.map { |m| m["key"] }
          list.each do |meta|
            assert_equal %w[key modified_at sha256 size], meta.keys.sort, meta.inspect
            assert_kind_of Integer, meta["size"]
            assert_operator meta["size"], :>=, 0
            assert_match(/\A[0-9a-f]{64}\z/, meta["sha256"])
            assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/, meta["modified_at"])
            assert_in_delta Time.now.to_f, Time.iso8601(meta["modified_at"]).to_f, 60, meta.inspect
          end

          readme = list.find { |m| m["key"] == "docs/readme.txt" }
          assert_equal({ "size" => 5, "sha256" => Digest::SHA256.hexdigest("hello") }, readme.slice("size", "sha256"))
          empty = list.find { |m| m["key"] == "sp ace/ü.txt" }
          assert_equal({ "size" => 0, "sha256" => Digest::SHA256.hexdigest("") }, empty.slice("size", "sha256"))
        end
      end
    end
  end

  def test_missing_data_dir_fails_with_usage_error
    stdout, stderr, status = run_cli("--port", free_port.to_s)
    assert_equal 2, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
    assert_match(/--data-dir is required/, stderr)
    assert_match(/Usage:/, stderr)
  end

  def test_invalid_port_fails_with_usage_error
    with_tmpdir do |dir|
      _, stderr, status = run_cli("--data-dir", dir, "--port", "abc")
      assert_equal 2, status.exitstatus
      assert_match(/invalid port/, stderr)
    end
  end

  def test_help_prints_usage_and_exits_zero
    stdout, _, status = run_cli("--help")
    assert_equal 0, status.exitstatus
    assert_match(/Usage: syncbox-server --data-dir <path> \[--port <n>\]/, stdout)
  end

  def test_unwritable_data_dir_fails
    skip "root can write anywhere" if Process.uid.zero?

    with_tmpdir do |dir|
      File.chmod(0o500, dir)
      begin
        _, stderr, status = run_cli("--data-dir", File.join(dir, "store"), "--port", free_port.to_s)
        assert_equal 1, status.exitstatus
        assert_match(/Permission denied/, stderr)
      ensure
        File.chmod(0o700, dir)
      end
    end
  end

  private

  # Environment overrides that unset inherited SYNCBOX_* values (a nil value
  # removes the variable in Process.spawn), so tests are hermetic even when
  # the container image sets defaults.
  def clean_env(extra = {})
    ENV.keys.grep(/\ASYNCBOX_/).to_h { |k| [k, nil] }.merge(extra)
  end

  # Runs the executable to completion with a timeout, so that a server which
  # unexpectedly starts listening cannot hang the whole suite.
  def run_cli(*args, env: {})
    Open3.popen3(clean_env(env), SERVER_BIN, *args) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      unless wait_thr.join(BOOT_TIMEOUT)
        Process.kill("KILL", wait_thr.pid)
        flunk "#{SERVER_BIN} #{args.join(' ')} did not exit within #{BOOT_TIMEOUT}s"
      end
      [out_reader.value, err_reader.value, wait_thr.value]
    end
  end

  # Sends one HTTP/1.1 request with the path exactly as given and returns the
  # status code.
  def raw_status(port, method, path, body: "")
    Socket.tcp("127.0.0.1", port, connect_timeout: 2) do |sock|
      sock.write("#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" \
                 "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      status_line = Timeout.timeout(5) { sock.gets }
      flunk "no response for #{method} #{path}" if status_line.nil?
      Integer(status_line.split(" ")[1], 10)
    end
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def spawn_server(args, env: {})
    Process.spawn(clean_env(env), SERVER_BIN, *args, out: File::NULL, err: File::NULL)
  end

  def with_server(args, env: {})
    pid = spawn_server(args, env: env)
    yield pid
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
        Timeout.timeout(BOOT_TIMEOUT) { Process.wait(pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        # already gone
      rescue Timeout::Error
        Process.kill("KILL", pid)
        Process.wait(pid)
      end
    end
  end

  def wait_for_healthz(port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    last_error = nil
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        return Net::HTTP.start("127.0.0.1", port, open_timeout: 1, read_timeout: 2) { |http| http.get("/healthz") }
      rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, EOFError => e
        last_error = e
        sleep 0.1
      end
    end
    flunk "server on port #{port} did not become healthy within #{BOOT_TIMEOUT}s (#{last_error.inspect})"
  end
end
