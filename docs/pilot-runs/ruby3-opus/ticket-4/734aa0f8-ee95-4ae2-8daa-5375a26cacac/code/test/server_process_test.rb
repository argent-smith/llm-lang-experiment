# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "net/http"
require "open3"
require "socket"

# Boots bin/syncbox-server as a real process and talks to it over HTTP.
class ServerProcessTest < Minitest::Test
  SERVER_BIN = File.expand_path("../bin/syncbox-server", __dir__)
  BOOT_TIMEOUT = 15

  def setup
    @tmp = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_serves_healthz_and_stops_cleanly_on_sigterm
    port = free_port
    data_dir = File.join(@tmp, "data")
    with_server("--data-dir", data_dir, "--port", port.to_s) do |pid|
      response = wait_for_healthz(port)
      assert_equal "200", response.code
      assert File.directory?(data_dir), "data dir should be created on startup"

      Process.kill("TERM", pid)
      _, status = Process.wait2(pid)
      assert_equal 0, status.exitstatus
    end
  end

  def test_reads_configuration_from_environment
    port = free_port
    env = { "SYNCBOX_DATA_DIR" => @tmp, "SYNCBOX_PORT" => port.to_s }
    with_server(env: env) do
      assert_equal "200", wait_for_healthz(port).code
    end
  end

  def test_blob_endpoints_answer_within_contract_over_http
    port = free_port
    with_server("--data-dir", @tmp, "--port", port.to_s) do
      wait_for_healthz(port)
      http = Net::HTTP.new("127.0.0.1", port)

      assert_equal "200", http.get("/blobs").code

      response = http.put("/blobs/0", "", "content-type" => "application/octet-stream")
      assert_equal "201", response.code
      assert_equal({ "key" => "0", "sha256" => Digest::SHA256.hexdigest(""), "size" => 0 }, JSON.parse(response.body))

      # Raw request targets as a fuzzer might send them, including ones the
      # HTTP parser itself rejects (bad bytes, oversized paths).
      ["/blobs/", "/blobs/../x", "/blobs/%2e%2e/x", "/blobs/%zz", "/blobs/%ED%A0%80", "/blobs/%00",
       "/blobs/\xFF".b, "/blobs/a b", "/blobs/#{'x' * 300}", "/blobs/#{'x/' * 3000}x", "/blobs/#{'y' * 13_000}",
       "/blobs/0/x"].each do |path|
        assert_equal "400", raw_status(port, "PUT", path), "PUT #{path[0, 40].inspect}"
      end

      # Deeply nested key (within PATH_MAX): listing must not blow the
      # request thread's stack.
      deep = "#{'a/' * 1800}f"
      assert_equal "201", http.put("/blobs/#{deep}", "x", "content-type" => "application/octet-stream").code

      listing = http.get("/blobs")
      assert_equal "200", listing.code
      assert_equal ["0", deep], JSON.parse(listing.body).map { |e| e["key"] }
    end
  end

  def test_put_then_get_round_trips_bytes_over_http
    port = free_port
    with_server("--data-dir", @tmp, "--port", port.to_s) do
      wait_for_healthz(port)
      http = Net::HTTP.new("127.0.0.1", port)
      body = Random.new(42).bytes(300_000)

      response = http.put("/blobs/docs/readme.txt", body, "content-type" => "application/octet-stream")
      assert_equal "201", response.code
      assert_equal({ "key" => "docs/readme.txt", "sha256" => Digest::SHA256.hexdigest(body), "size" => body.bytesize },
                   JSON.parse(response.body))
      assert_equal body, File.binread(File.join(@tmp, "blobs", "docs", "readme.txt"))

      response = http.get("/blobs/docs/readme.txt")
      assert_equal "200", response.code
      assert_equal body, response.body.b

      assert_equal "404", http.get("/blobs/docs/missing.txt").code
    end
  end

  def test_delete_removes_blob_over_http
    port = free_port
    with_server("--data-dir", @tmp, "--port", port.to_s) do
      wait_for_healthz(port)
      http = Net::HTTP.new("127.0.0.1", port)
      http.put("/blobs/docs/readme.txt", "hello", "content-type" => "application/octet-stream")

      response = http.delete("/blobs/docs/readme.txt")
      assert_equal "204", response.code
      assert_nil response.body
      assert_equal "404", http.get("/blobs/docs/readme.txt").code
      assert_equal [], JSON.parse(http.get("/blobs").body)
      assert_equal "404", http.delete("/blobs/docs/readme.txt").code

      ["/blobs/", "/blobs/../x", "/blobs/%2e%2e/x", "/blobs/%zz", "/blobs/\xFF".b].each do |path|
        assert_equal "400", raw_status(port, "DELETE", path), "DELETE #{path.inspect}"
      end
    end
  end

  def test_exits_with_error_when_data_dir_is_missing
    _out, err, status = Open3.capture3({ "SYNCBOX_DATA_DIR" => nil }, SERVER_BIN, "--port", free_port.to_s)
    assert_equal 2, status.exitstatus
    assert_match(/--data-dir/, err)
  end

  def test_exits_with_error_on_invalid_port
    _out, err, status = Open3.capture3(SERVER_BIN, "--data-dir", @tmp, "--port", "http")
    assert_equal 2, status.exitstatus
    assert_match(/--port/, err)
  end

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def with_server(*args, env: {})
    env = { "SYNCBOX_DATA_DIR" => nil, "SYNCBOX_PORT" => nil }.merge(env)
    log = File.join(@tmp, "server.log")
    pid = Process.spawn(env, SERVER_BIN, *args, %i[out err] => log)
    yield pid
  rescue Minitest::Assertion
    puts "--- server log ---", File.read(log)
    raise
  ensure
    if pid
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # Already exited and reaped.
      end
    end
  end

  # Sends a request with a verbatim request target; returns the status code.
  def raw_status(port, method, target)
    TCPSocket.open("127.0.0.1", port) do |socket|
      socket.write("#{method} ".b + target.b + " HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".b)
      socket.read[%r{\AHTTP/1\.\d (\d{3})}, 1]
    end
  end

  def wait_for_healthz(port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    begin
      Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/healthz"))
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
      retry
    end
  end
end
