# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "rack/test"
require "tmpdir"
require "syncbox"

module Syncbox
  module TestSupport
    ROOT = File.expand_path("..", __dir__)
    SERVER_BIN = File.join(ROOT, "bin", "syncbox-server")

    # Свободный TCP-порт на loopback.
    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    # Ждёт, пока сервер начнёт отвечать на GET /healthz (или процесс умрёт).
    def wait_for_healthz(port, pid: nil, timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        begin
          return Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/healthz"))
        rescue SystemCallError, Net::ReadTimeout, Net::OpenTimeout
          # ещё не поднялся
        end
        if pid && Process.waitpid(pid, Process::WNOHANG)
          raise "server process #{pid} exited early with #{$?.inspect}"
        end
        raise "server on port #{port} did not become healthy within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end
  end
end
