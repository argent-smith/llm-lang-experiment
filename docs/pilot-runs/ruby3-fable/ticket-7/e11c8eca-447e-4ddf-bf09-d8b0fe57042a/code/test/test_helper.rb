# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "rack/test"
require "digest"
require "fileutils"
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

require "json"
require "net/http"

module Syncbox
  module TestSupport
    CLIENT_BIN = File.join(ROOT, "bin", "syncbox")

    # Настоящий bin/syncbox-server отдельным процессом — для тестов клиента.
    class ServerProcess
      include TestSupport

      attr_reader :port, :data_dir, :pid, :log

      def initialize(data_dir)
        @data_dir = data_dir
        @port = free_port
        @log = File.join(Dir.tmpdir, "syncbox-server-#{@port}.log")
        env = { "SYNCBOX_DATA_DIR" => nil, "SYNCBOX_PORT" => nil }
        @pid = Process.spawn(env, SERVER_BIN, "--data-dir", data_dir, "--port", port.to_s, out: @log, err: @log)
        wait_for_healthz(port, pid: @pid)
      end

      def url
        "http://127.0.0.1:#{port}"
      end

      def stop
        return unless @pid

        if Process.waitpid(@pid, Process::WNOHANG).nil?
          Process.kill("TERM", @pid)
          Process.wait(@pid)
        end
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      ensure
        @pid = nil
        FileUtils.rm_f(@log)
      end

      def http
        Net::HTTP.new("127.0.0.1", port)
      end

      # [key, ...] всех блобов на сервере.
      def keys
        list.map { |meta| meta["key"] }
      end

      def list
        JSON.parse(http.get("/blobs").body)
      end

      # Содержимое блоба (binary) или nil при 404.
      def blob(key)
        response = http.get("/blobs/#{Syncbox::Client::Api.escape_key(key)}")
        response.code == "200" ? response.body.b : nil
      end

      def put(key, body)
        request = Net::HTTP::Put.new("/blobs/#{Syncbox::Client::Api.escape_key(key)}", "content-type" => "application/octet-stream")
        request.body = body
        response = http.request(request)
        raise "PUT #{key} -> #{response.code}" unless response.code == "201"

        JSON.parse(response.body)
      end
    end
  end
end
