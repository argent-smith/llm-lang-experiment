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

      # Сколько ждать корректного завершения по SIGTERM, прежде чем убить
      # процесс: сервер — не предмет этих тестов, его зависание на остановке
      # не должно подвешивать весь прогон.
      STOP_TIMEOUT = 10

      def stop
        return unless @pid

        if Process.waitpid(@pid, Process::WNOHANG).nil?
          Process.kill("TERM", @pid)
          unless wait_exit(STOP_TIMEOUT)
            warn "test server #{@pid} did not exit within #{STOP_TIMEOUT}s after SIGTERM, killing it\n#{File.read(@log)}"
            Process.kill("KILL", @pid)
            Process.wait(@pid)
          end
        end
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      ensure
        @pid = nil
        FileUtils.rm_f(@log)
      end

      # true, если процесс завершился за timeout секунд.
      def wait_exit(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until Process.waitpid(@pid, Process::WNOHANG)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
        true
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

require "socket"

module Syncbox
  module TestSupport
    # Минимальный HTTP/1.1-сервер на TCPServer для проверки клиента против
    # недоверенных ответов и сетевых сбоев: одно соединение — один запрос
    # (ответ с Connection: close), тело запроса читается по Content-Length.
    # Ответ — по таблице routes, "METHOD /path" =>
    #   [code, body]       — обычный ответ;
    #   proc { |body| … }  — ответ, вычисленный по телу запроса ([code, body]);
    #   :drop              — закрыть соединение, не ответив;
    #   :hang              — не отвечать вовсе (соединение висит до stop).
    # Неизвестный путь — 404. Все полученные запросы ("METHOD /path")
    # копятся в #requests.
    class FakeServer
      attr_reader :port, :requests

      def initialize(routes)
        @routes = routes
        @requests = []
        @hung = []
        @socket = TCPServer.new("127.0.0.1", 0)
        @port = @socket.addr[1]
        @thread = Thread.new { serve }
      end

      def url
        "http://127.0.0.1:#{port}"
      end

      # Перестаёт принимать соединения (дальше — connection refused), как
      # будто сервер умер; уже принятые зависшие соединения остаются.
      def refuse_connections
        @socket.close unless @socket.closed?
      end

      def stop
        refuse_connections
        @hung.each { |client| client.close rescue nil }
        @thread.join(5)
      end

      # Тело листинга GET /blobs для пар [key, содержимое].
      def self.listing(*entries)
        JSON.generate(entries.map do |key, body|
          { "key" => key, "size" => body.bytesize, "sha256" => Digest::SHA256.hexdigest(body), "modified_at" => "2026-01-01T00:00:00Z" }
        end)
      end

      # Маршрут PUT, принимающий тело как настоящий сервер: 201 с key, sha256 и size.
      def self.put_ok(key)
        ->(body) { [201, JSON.generate("key" => key, "sha256" => Digest::SHA256.hexdigest(body), "size" => body.bytesize)] }
      end

      private

      def serve
        loop do
          handle(@socket.accept)
        end
      rescue IOError, SystemCallError
        nil # сокет закрыт в stop / refuse_connections
      end

      def handle(client)
        line = client.gets
        return client.close unless line

        headers = client.gets("\r\n\r\n").to_s
        length = headers[/^content-length:[ \t]*(\d+)/i, 1].to_i
        body = length.positive? ? client.read(length).to_s : ""
        method, path, = line.split(" ")
        @requests << "#{method} #{path}"
        route = @routes.fetch("#{method} #{path}", [404, "{\"error\":\"not_found\"}"])
        case route
        when :hang
          @hung << client
          return
        when :drop
          return client.close
        when Proc
          code, response = route.call(body)
        else
          code, response = route
        end
        client.write("HTTP/1.1 #{code} X\r\nContent-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
        client.close
      rescue IOError, SystemCallError
        client.close rescue nil
      end
    end
  end
end
