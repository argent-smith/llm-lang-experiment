# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Syncbox
  module Client
    # HTTP API сервера глазами клиента: одно keep-alive соединение на всё
    # время работы команды. Любая сетевая ошибка или ответ не из контракта
    # превращается в Client::Error с понятным сообщением.
    class Api
      OCTET_STREAM = "application/octet-stream"

      # Таймауты, чтобы клиент не висел на недоступном сервере.
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60
      WRITE_TIMEOUT = 60

      # Сколько байт тела неожиданного ответа показывать в сообщении об ошибке.
      ERROR_BODY_LIMIT = 200

      NETWORK_ERRORS = [
        SocketError, SystemCallError, IOError, EOFError, Timeout::Error,
        Net::ProtocolError, OpenSSL::SSL::SSLError
      ].freeze

      # Открывает соединение с сервером на время блока.
      def self.open(base_url)
        http = Net::HTTP.new(base_url.host, base_url.port)
        http.use_ssl = base_url.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.write_timeout = WRITE_TIMEOUT
        begin
          http.start
        rescue *NETWORK_ERRORS => e
          raise Error, "cannot connect to server #{base_url}: #{e.message}"
        end
        begin
          yield new(http, base_url)
        ensure
          http.finish if http.started?
        end
      end

      # key → путь в URL. В сегментах остаются как есть только unreserved
      # символы RFC 3986, всё прочее (включая не-ASCII) percent-кодируется
      # побайтно. `/` между сегментами не кодируется: сервер декодирует key
      # однократно, и `%2F` превратился бы в разделитель.
      def self.escape_key(key)
        key.split("/", -1).map { |segment| escape_segment(segment) }.join("/")
      end

      def self.escape_segment(segment)
        segment.b.gsub(/[^A-Za-z0-9\-._~]/) { |byte| format("%%%02X", byte.ord) }
      end

      def initialize(http, base_url)
        @http = http
        @base_url = base_url
        @prefix = base_url.path
      end

      # GET /blobs → массив { "key", "size", "sha256", "modified_at" }.
      def list_blobs
        label = "GET /blobs"
        response = request(label, Net::HTTP::Get.new("#{@prefix}/blobs"))
        expect!(label, response, "200")
        list = parse_json(label, response)
        raise Error, "#{label}: expected a JSON array, got #{list.class}" unless list.is_a?(Array)

        list
      end

      # PUT /blobs/{key} с телом из io (ровно size байт, потоково, без
      # загрузки файла в память) → { "key", "sha256", "size" }.
      def put_blob(key, io, size)
        label = "PUT /blobs/#{key}"
        request = Net::HTTP::Put.new("#{@prefix}/blobs/#{self.class.escape_key(key)}",
                                     "content-type" => OCTET_STREAM, "content-length" => size.to_s)
        request.body_stream = io
        response = request(label, request)
        expect!(label, response, "201")
        parse_json(label, response)
      end

      private

      def request(label, req)
        @http.request(req)
      rescue *NETWORK_ERRORS => e
        raise Error, "#{label}: request to #{@base_url} failed: #{e.message}"
      end

      def expect!(label, response, code)
        return if response.code == code

        raise Error, "#{label}: server responded #{response.code}#{describe(response)}"
      end

      # Короткое описание тела неожиданного ответа: message из JSON-ошибки
      # сервера, иначе обрезанное тело.
      def describe(response)
        body = response.body.to_s
        return "" if body.empty?

        text = begin
          payload = JSON.parse(body)
          payload.is_a?(Hash) ? (payload["message"] || payload["error"]) : nil
        rescue JSON::ParserError
          nil
        end
        ": #{text || body.b[0, ERROR_BODY_LIMIT].scrub}"
      end

      def parse_json(label, response)
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError => e
        raise Error, "#{label}: server returned invalid JSON: #{e.message}"
      end
    end
  end
end
