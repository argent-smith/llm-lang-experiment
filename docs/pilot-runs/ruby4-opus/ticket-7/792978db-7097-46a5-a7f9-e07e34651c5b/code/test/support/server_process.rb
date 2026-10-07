# frozen_string_literal: true

require "net/http"
require "socket"

# Runs bin/syncbox-server as a separate process, the way run-server does
# inside the container. Including tests set @tmp (a scratch directory for the
# server log) and @port, and call stop_server in teardown.
module ServerProcess
  SERVER_BIN = File.expand_path("../../bin/syncbox-server", __dir__)
  BOOT_TIMEOUT = 20

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def start_server(*args, env: {})
    @log = File.join(@tmp, "server.log")
    @pid = Process.spawn(clean_env.merge(env), SERVER_BIN, *args, %i[out err] => @log)
    deadline = Time.now + BOOT_TIMEOUT
    loop do
      return if (get("/healthz") rescue nil)
      flunk "server exited during boot:\n#{File.read(@log)}" if Process.wait(@pid, Process::WNOHANG)
      flunk "server did not boot in #{BOOT_TIMEOUT}s:\n#{File.read(@log)}" if Time.now > deadline
      sleep 0.1
    end
  end

  def stop_server
    return unless @pid

    Process.kill("KILL", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # Ignore SYNCBOX_* settings that may be set in the test container.
  def clean_env
    { "SYNCBOX_DATA_DIR" => nil, "SYNCBOX_PORT" => nil, "SYNCBOX_SERVER" => nil }
  end

  def get(path)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 1, read_timeout: 5) { |http| http.get(path) }
  end
end
