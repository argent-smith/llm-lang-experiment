# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Syncbox
  module Client
    # The Syncbox HTTP API (syncbox-openapi.yaml) over one keep-alive
    # connection. Network failures and unexpected answers raise Error.
    #
    # Every network operation has a time limit, so an unreachable or stuck
    # server fails the request instead of hanging the client: connecting
    # (name lookup, TCP and TLS handshake), each read of the answer, and each
    # write of a request body.
    class Remote
      # In seconds.
      Timeouts = Data.define(:open, :read, :write)
      TIMEOUTS = Timeouts.new(open: 10, read: 60, write: 60)

      LIST = "GET /blobs"

      # Failures of the connection itself, as opposed to an HTTP answer.
      NETWORK_ERRORS = [
        SystemCallError, SocketError, IOError, EOFError, Timeout::Error,
        OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      ].freeze

      # Failures to connect at all: the request never got to the server.
      CONNECT_ERRNOS = [
        Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EHOSTDOWN, Errno::ENETDOWN,
        Errno::EADDRNOTAVAIL
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
      def self.open(base_url, timeouts: TIMEOUTS)
        remote = new(base_url, timeouts: timeouts)
        yield remote
      ensure
        remote&.close
      end

      def initialize(base_url, timeouts: TIMEOUTS)
        @base_url = base_url
        @base_path = base_url.path.chomp("/")
        @timeouts = timeouts
        @http = Net::HTTP.new(base_url.host, base_url.port)
        @http.use_ssl = base_url.scheme == "https"
        # Covers the name lookup and the TLS handshake as well.
        @http.open_timeout = timeouts.open
        @http.read_timeout = timeouts.read
        @http.write_timeout = timeouts.write
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
        response = request(Net::HTTP::Get.new("#{@base_path}/blobs"), LIST)
        expect(response, "200", LIST)
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
        request(req, "GET #{key}") do |response|
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
        answer = JSON.parse(expect(request(req, "PUT #{key}"), "201", "PUT #{key}").body.to_s)
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

      # Sends req, named what in errors. With a block, the response body is
      # left for the block to read; if the block raises, Net::HTTP drops the
      # connection. After a network failure the connection is dropped too, and
      # the next request opens a new one.
      def request(req, what, &block)
        @http.start unless @http.started?
        @http.request(req, &block)
      rescue *NETWORK_ERRORS => e
        @http.finish if @http.started?
        raise Error, network_failure(e, what)
      end

      # What went wrong with the connection, for a person to read.
      def network_failure(error, what)
        server = "server #{@base_url}"
        case error
        when Net::OpenTimeout, SocketError, *CONNECT_ERRNOS
          "cannot reach #{server}#{" for #{what}" unless what == LIST}: #{connect_reason(error)}"
        when Net::ReadTimeout
          "no answer from #{server} to #{what} within #{seconds(@timeouts.read)}"
        when Net::WriteTimeout
          "timed out sending #{what} to #{server}: no progress for #{seconds(@timeouts.write)}"
        when EOFError
          "connection to #{server} closed during #{what}"
        when SystemCallError
          "connection to #{server} failed during #{what}: #{LocalDir.reason(error)}"
        else
          "connection to #{server} failed during #{what}: #{error.message}"
        end
      end

      def connect_reason(error)
        case error
        when Net::OpenTimeout
          "connection timed out after #{seconds(@timeouts.open)}"
        when SocketError
          # Net::HTTP rewords it: "Failed to open TCP connection to h:80 (getaddrinfo: <why>)".
          why = error.message[/getaddrinfo(?:\(3\))?: ([^)]*)/, 1]
          why ? "cannot resolve host name #{@base_url.host}: #{why}" : error.message
        else
          LocalDir.reason(error)
        end
      end

      def seconds(value)
        "#{value} second#{'s' unless value == 1}"
      end

      def expect(response, code, what)
        return response if response.code == code

        detail = response.body.to_s.lines.first.to_s.strip[0, 200]
        raise Error, "server answered #{what} with HTTP #{response.code}#{": #{detail}" unless detail.empty?}"
      end
    end
  end
end
