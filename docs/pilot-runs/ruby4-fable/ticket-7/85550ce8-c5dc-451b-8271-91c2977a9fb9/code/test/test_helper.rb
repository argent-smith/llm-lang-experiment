# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rack/test"
require "tmpdir"
require "net/http"
require "socket"
require "timeout"
require "syncbox/server"
require "syncbox/client"

module TestHelpers
  ROOT = File.expand_path("..", __dir__)

  def with_tmpdir(&block)
    Dir.mktmpdir("syncbox-test-", &block)
  end
end

# Boots the real server executable (bin/syncbox-server) as a child process so
# that tests can talk to it over HTTP — the same surface the external
# acceptance checks use.
module ServerProcessHelpers
  SERVER_BIN = File.join(TestHelpers::ROOT, "bin", "syncbox-server")
  BOOT_TIMEOUT = 15

  # Environment overrides that unset inherited SYNCBOX_* values (a nil value
  # removes the variable in Process.spawn), so tests are hermetic even when
  # the container image sets defaults.
  def clean_env(extra = {})
    ENV.keys.grep(/\ASYNCBOX_/).to_h { |k| [k, nil] }.merge(extra)
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

  # Boots a server on a free port with its storage under +dir+ and yields the
  # port once /healthz answers.
  def with_running_server(dir)
    port = free_port
    with_server(%W[--data-dir #{dir} --port #{port}]) do
      wait_for_healthz(port)
      yield port
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
