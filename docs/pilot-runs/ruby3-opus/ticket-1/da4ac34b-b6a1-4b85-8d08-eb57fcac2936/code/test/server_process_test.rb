# frozen_string_literal: true

require "test_helper"
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
