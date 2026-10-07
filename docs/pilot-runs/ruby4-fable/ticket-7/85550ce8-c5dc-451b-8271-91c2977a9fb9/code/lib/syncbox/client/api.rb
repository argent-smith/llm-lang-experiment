# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Syncbox
  module Client
    # Thin HTTP client for the server API in syncbox-openapi.yaml. One
    # instance keeps one keep-alive connection, opened on first use and
    # closed by #close. Network-level failures surface as Unreachable,
    # unexpected statuses as HttpError and malformed bodies as ProtocolError,
    # so callers never see Net::HTTP internals.
    class Api
      class Error < StandardError; end

      # The server could not be reached or the connection broke.
      class Unreachable < Error; end

      # The server answered, but with a status the operation does not expect.
      class HttpError < Error
        attr_reader :status, :body

        def initialize(method, path, response)
          @status = response.code.to_i
          @body = response.body.to_s
          super("server answered #{response.code} #{response.message} to #{method} #{path}#{detail}")
        end

        private

        def detail
          return "" if body.empty?

          text = begin
            parsed = JSON.parse(body)
            parsed.is_a?(Hash) ? parsed.values_at("detail", "error").compact.first.to_s : body
          rescue JSON::ParserError
            body
          end
          text = text.strip
          text.empty? ? "" : ": #{text[0, 200]}"
        end
      end

      # The server answered 2xx but the body is not what the schema promises.
      class ProtocolError < Error; end

      RemoteBlob = Struct.new(:key, :size, :sha256, :modified_at, keyword_init: true)
      PutResult = Struct.new(:key, :size, :sha256, keyword_init: true)

      SHA256_HEX = /\A[0-9a-f]{64}\z/
      OCTET_STREAM = "application/octet-stream"

      NETWORK_ERRORS = [
        SocketError, SystemCallError, IOError, EOFError, Timeout::Error,
        Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Net::ProtocolError, OpenSSL::SSL::SSLError
      ].freeze

      attr_reader :base_url

      # +base_url+ is a URI::HTTP as produced by Options (no trailing slash).
      def initialize(base_url, open_timeout: 10, read_timeout: 60, write_timeout: 60)
        @base_url = base_url
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @write_timeout = write_timeout
        @http = nil
        @requests_on_connection = 0
      end

      # GET /blobs → Array<RemoteBlob>, sorted by key.
      def list
        path = "#{@base_url.path}/blobs"
        response = request(path) { Net::HTTP::Get.new(path) }
        raise HttpError.new("GET", path, response) unless response.code == "200"

        parse_list(path, response.body)
      end

      # PUT /blobs/{key} with the contents of the file at +path+. The file is
      # streamed, not slurped. Returns the server's PutResult.
      def put(key, path)
        request_path = blob_path(key)
        response = request(request_path) do
          # A fresh handle for every attempt: a retried request must send the
          # whole body again, which a half-consumed stream cannot do.
          file = File.open(path, "rb")
          req = Net::HTTP::Put.new(request_path, "content-type" => OCTET_STREAM)
          req["content-length"] = file.size.to_s
          req.body_stream = file
          [req, file]
        end
        raise HttpError.new("PUT", request_path, response) unless response.code == "201"

        parse_put(request_path, response.body)
      end

      def close
        @http&.finish if @http&.started?
      rescue IOError
        nil
      ensure
        @http = nil
        @requests_on_connection = 0
      end

      # Percent-encodes a key for use inside a URL path: every byte except
      # RFC 3986 unreserved characters and "/" is escaped, so the server (which
      # decodes exactly once) sees the key byte for byte. Keys are UTF-8.
      def self.encode_key(key)
        key.b.gsub(%r{[^A-Za-z0-9\-._~/]}) { |c| format("%%%02X", c.ord) }
      end

      def blob_path(key)
        "#{@base_url.path}/blobs/#{self.class.encode_key(key)}"
      end

      private

      # Sends the request built by the block (which returns either a request
      # or [request, io_to_close]) and returns the response. Network failures
      # become Unreachable; a failure on a connection that already served a
      # request is retried once on a fresh connection, since the server may
      # simply have closed an idle keep-alive connection.
      def request(path)
        attempts = 0
        loop do
          attempts += 1
          reused = @requests_on_connection.positive?
          # Outside the rescue below: a local failure while building the
          # request (e.g. the file vanished) is not a network problem.
          req, io = yield
          begin
            response = http.request(req)
            @requests_on_connection += 1
            return response
          rescue *NETWORK_ERRORS => e
            close
            next if reused && attempts == 1

            raise Unreachable, "cannot reach server at #{@base_url}: #{e.message} (#{req.method} #{path})"
          ensure
            io&.close
          end
        end
      end

      def http
        return @http if @http&.started?

        http = Net::HTTP.new(@base_url.host, @base_url.port)
        http.use_ssl = @base_url.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @write_timeout
        # Retrying is our job (see #request): Net::HTTP would resend a request
        # whose body stream has already been consumed.
        http.max_retries = 0
        # A body shorter than its Content-Length means the connection broke;
        # report that instead of handing a truncated body to the caller.
        http.ignore_eof = false
        http.start
        @requests_on_connection = 0
        @http = http
      end

      def parse_list(path, body)
        data = parse_json(path, body)
        raise ProtocolError, "GET #{path}: expected a JSON array, got #{data.class}" unless data.is_a?(Array)

        data.map do |item|
          unless item.is_a?(Hash) && item["key"].is_a?(String) && item["sha256"].to_s.match?(SHA256_HEX)
            raise ProtocolError, "GET #{path}: malformed list entry #{item.inspect[0, 200]}"
          end

          RemoteBlob.new(key: item["key"], size: item["size"], sha256: item["sha256"], modified_at: item["modified_at"])
        end.sort_by(&:key)
      end

      def parse_put(path, body)
        data = parse_json(path, body)
        unless data.is_a?(Hash) && data["key"].is_a?(String) && data["sha256"].to_s.match?(SHA256_HEX)
          raise ProtocolError, "PUT #{path}: malformed response #{body.to_s[0, 200].inspect}"
        end

        PutResult.new(key: data["key"], size: data["size"], sha256: data["sha256"])
      end

      def parse_json(path, body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError => e
        raise ProtocolError, "#{path}: response is not valid JSON (#{e.message[0, 100]})"
      end
    end
  end
end
