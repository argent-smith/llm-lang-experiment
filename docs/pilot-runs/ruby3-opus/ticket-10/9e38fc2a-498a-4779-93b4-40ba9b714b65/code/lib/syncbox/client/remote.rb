# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Syncbox
  module Client
    # The Syncbox HTTP API (syncbox-openapi.yaml) over one keep-alive
    # connection. Network failures and unexpected answers raise Error.
    class Remote
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60
      WRITE_TIMEOUT = 60

      # Failures of the connection itself, as opposed to an HTTP answer.
      NETWORK_ERRORS = [
        SystemCallError, SocketError, IOError, EOFError, Timeout::Error,
        OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      ].freeze

      # Carries an error raised by a caller's block out through Net::HTTP, so
      # that a local failure (say, a full disk) isn't reported as a network one.
      class BlockError < StandardError
        attr_reader :error

        def initialize(error)
          super(error.message)
          @error = error
        end
      end
      private_constant :BlockError

      # Yields a Remote for base_url (a URI::HTTP) and closes its connection.
      def self.open(base_url)
        remote = new(base_url)
        yield remote
      ensure
        remote&.close
      end

      def initialize(base_url)
        @base_url = base_url
        @base_path = base_url.path.chomp("/")
        @http = Net::HTTP.new(base_url.host, base_url.port)
        @http.use_ssl = base_url.scheme == "https"
        @http.open_timeout = OPEN_TIMEOUT
        @http.read_timeout = READ_TIMEOUT
        @http.write_timeout = WRITE_TIMEOUT
        # A body cut short of its Content-Length is an error, not the whole blob.
        @http.ignore_eof = false
        # PUT is idempotent, but a retried streamed body would be sent empty.
        @http.max_retries = 0
      end

      def close
        @http.finish if @http.started?
      end

      # GET /blobs: [{"key", "size", "sha256", "modified_at"}].
      def list
        response = request(Net::HTTP::Get.new("#{@base_path}/blobs"))
        expect(response, "200", "GET /blobs")
        entries = JSON.parse(response.body)
        unless entries.is_a?(Array) && entries.all? { |e| e.is_a?(Hash) && e["key"].is_a?(String) && e["sha256"].is_a?(String) }
          raise Error, "unexpected response from server to GET /blobs: not a list of blobs"
        end

        entries
      rescue JSON::ParserError
        raise Error, "unexpected response from server to GET /blobs: invalid JSON"
      end

      # GET /blobs/{key}, yielding the body in chunks as they arrive. Errors
      # raised by the block propagate unchanged.
      def get(key)
        # identity: the body is the blob's bytes as stored, nothing to decode.
        req = Net::HTTP::Get.new(blob_path(key), "accept-encoding" => "identity")
        request(req) do |response|
          expect(response, "200", "GET #{key}")
          response.read_body do |chunk|
            yield chunk
          rescue StandardError => e
            raise BlockError, e
          end
        end
      rescue BlockError => e
        raise e.error
      end

      # PUT /blobs/{key}, streaming size bytes from io as the body. Returns the
      # server's answer, {"key", "sha256", "size"} ({} if it isn't a JSON object).
      def put(key, io, size)
        req = Net::HTTP::Put.new(blob_path(key))
        req["content-type"] = "application/octet-stream"
        req.content_length = size
        req.body_stream = io
        answer = JSON.parse(expect(request(req), "201", "PUT #{key}").body.to_s)
        answer.is_a?(Hash) ? answer : {}
      rescue JSON::ParserError
        {}
      end

      # Percent-encodes each segment of a key; "/" stays a separator.
      def self.escape_key(key)
        key.split("/", -1).map { |segment| URI.encode_uri_component(segment) }.join("/")
      end

      private

      def blob_path(key)
        "#{@base_path}/blobs/#{self.class.escape_key(key)}"
      end

      # With a block, the response body is left for the block to read; if the
      # block raises, Net::HTTP drops the connection.
      def request(req, &block)
        @http.start unless @http.started?
        @http.request(req, &block)
      rescue *NETWORK_ERRORS => e
        @http.finish if @http.started?
        raise Error, "cannot reach server #{@base_url}: #{network_reason(e)}"
      end

      def network_reason(error)
        case error
        when Timeout::Error then "timed out"
        when SystemCallError then LocalDir.reason(error)
        else error.message
        end
      end

      def expect(response, code, what)
        return response if response.code == code

        detail = response.body.to_s.lines.first.to_s.strip[0, 200]
        raise Error, "server answered #{what} with HTTP #{response.code}#{": #{detail}" unless detail.empty?}"
      end
    end
  end
end
