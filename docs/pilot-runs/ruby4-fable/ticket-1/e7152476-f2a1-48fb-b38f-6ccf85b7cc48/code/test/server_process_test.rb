# frozen_string_literal: true

require "test_helper"
require "net/http"
require "socket"
require "timeout"
require "open3"

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
