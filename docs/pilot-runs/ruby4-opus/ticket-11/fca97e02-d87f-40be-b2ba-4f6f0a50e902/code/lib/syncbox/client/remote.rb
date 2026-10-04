# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module Syncbox
  module Client
    # The server's HTTP API (syncbox-openapi.yaml), over one keep-alive
    # connection. Network failures and unexpected responses raise Error, or
    # Unreachable if the server cannot be reached at all.
    #
    # No network operation waits forever: connecting (name resolution
    # included), sending a request and every wait for the response have a
    # timeout.
    class Remote
      # Metadata of a stored blob as listed by GET /blobs. +modified_at+ is
      # the ISO 8601 string as listed: only sync needs it, and parses it.
      Blob = Data.define(:key, :size, :sha256, :modified_at) do
        def initialize(key:, size:, sha256:, modified_at: nil) = super
      end

      # The blob asked for is not (or no longer) stored on the server.
      class NotFound < Error; end

      # The server cannot be connected to, or does not answer in time. The
      # requests that would follow would fail the same way (after a timeout,
      # each waiting as long), so commands stop at it. A network error on an
      # established connection (reset or closed in the middle of a request)
      # is a plain Error: it fails that request only, and the next request
      # connects anew.
      class Unreachable < Error; end

      # Seconds.
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60
      WRITE_TIMEOUT = 60
      # The server answers a PUT only once it has received and stored the
      # whole body, which takes longer the larger the blob: the read timeout
      # of an upload grows by a second for every this many bytes.
      PUT_BYTES_PER_SECOND = 4 * 1024 * 1024

      NETWORK_ERRORS = [
        SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
        Net::HTTPBadResponse, Net::ProtocolError
      ].freeze

      # Bytes percent-encoded in a key: all but unreserved characters and "/",
      # which stays literal as the separator of the key's segments.
      KEY_UNSAFE = %r{[^A-Za-z0-9\-._~/]}n

      # How Net::HTTP words every error in connecting: "Failed to open TCP
      # connection to host:port (<the original message>)".
      CONNECT_FAILED = /\AFailed to open TCP connection to .*? \((.*)\)\z/m

      def self.open(url, **timeouts)
        remote = new(url, **timeouts)
        yield remote
      ensure
        remote&.close
      end

      def initialize(url, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT)
        @url = url
        @base_path = url.path.sub(%r{/+\z}, "")
        @read_timeout = read_timeout
        @http = Net::HTTP.new(url.host, url.port)
        @http.use_ssl = url.scheme == "https"
        @http.open_timeout = open_timeout
        @http.read_timeout = read_timeout
        @http.write_timeout = write_timeout
        # A retried PUT would resend a body stream that is already consumed.
        @http.max_retries = 0
        # A connection closed before the whole Content-Length has arrived is
        # an error, not the end of a shorter blob.
        @http.ignore_eof = false
      end

      def close
        @http.finish if @http.started?
      end

      # All stored blobs: {key => Blob}.
      def list
        response = request(Net::HTTP::Get.new("#{@base_path}/blobs"), "list blobs")
        expect(response, Net::HTTPOK, "list blobs")
        parse_list(response.body)
      end

      # Uploads the contents of +io+ under +key+, replacing a stored blob.
      # Returns the SHA-256 the server reports for what it stored, or nil if
      # its answer does not say.
      def put(key, io)
        request = Net::HTTP::Put.new(blob_path(key))
        request["content-type"] = "application/octet-stream"
        # Chunked rather than a Content-Length taken up front: a file that
        # grows or shrinks while being sent still makes a well-formed request.
        request["transfer-encoding"] = "chunked"
        request.body_stream = io
        size = io.respond_to?(:size) ? io.size : 0
        response = with_read_timeout(@read_timeout + (size / PUT_BYTES_PER_SECOND)) do
          expect(request(request, "upload #{key}"), Net::HTTPCreated, "upload #{key}")
        end
        stored_sha256(response.body)
      end

      # Downloads the blob stored under +key+, yielding its contents in chunks.
      # Raises NotFound if there is no such blob. The block must not raise
      # SystemCallError: it would be taken for a network error.
      def get(key)
        action = "download #{key}"
        request(Net::HTTP::Get.new(blob_path(key)), action) do |response|
          raise NotFound, "cannot #{action}: not found on the server" if response.is_a?(Net::HTTPNotFound)

          expect(response, Net::HTTPOK, action)
          size = 0
          response.read_body do |chunk|
            size += chunk.bytesize
            yield chunk
          end
          length = response.content_length
          raise Error, "cannot #{action}: server #{@url} sent #{size} of #{length} bytes" if length && size != length
        end
      end

      def blob_path(key)
        encoded = key.b.gsub(KEY_UNSAFE) { |byte| format("%%%02X", byte.ord) }
        "#{@base_path}/blobs/#{encoded}"
      end

      private

      def request(request, action, &)
        connect(action)
        @http.request(request, &)
      rescue *NETWORK_ERRORS => e
        close_quietly
        # Net::HTTP itself reconnects a connection closed meanwhile.
        raise unreachable(action, e) if e.is_a?(Timeout::Error) || e.message.match?(CONNECT_FAILED)

        raise Error, "cannot #{action}: connection to server #{@url} failed: #{describe(e)}"
      end

      def connect(action)
        @http.start unless @http.started?
      rescue *NETWORK_ERRORS => e
        close_quietly
        raise unreachable(action, e)
      end

      def unreachable(action, error)
        Unreachable.new("cannot #{action}: server #{@url} is unreachable: #{describe(error)}")
      end

      # What went wrong, in words: Net::HTTP's messages say it in terms of its
      # internals ("Net::ReadTimeout with #<TCPSocket:(closed)>").
      def describe(error)
        detail = error.message[CONNECT_FAILED, 1] || error.message
        case error
        when Net::OpenTimeout then "could not connect within #{@http.open_timeout}s"
        when Net::ReadTimeout then "no response within #{@http.read_timeout}s"
        when Net::WriteTimeout then "could not send the request within #{@http.write_timeout}s"
        when SocketError then "cannot resolve host name #{@url.host} (#{detail})"
        when SystemCallError then error.class.new.message.downcase
        when EOFError then "the server closed the connection"
        else detail
        end
      end

      def with_read_timeout(seconds)
        @http.read_timeout = seconds
        yield
      ensure
        @http.read_timeout = @read_timeout
      end

      def expect(response, type, action)
        return response if response.is_a?(type)

        detail = response.body.to_s.strip[0, 200]
        detail = response.message if detail.empty?
        raise Error, "cannot #{action}: server answered #{response.code} #{detail}"
      end

      def parse_list(body)
        blobs = JSON.parse(body)
        raise KeyError unless blobs.is_a?(Array) && blobs.all?(Hash)

        blobs.to_h do |blob|
          [blob.fetch("key"), Blob.new(key: blob.fetch("key"), size: blob.fetch("size"), sha256: blob.fetch("sha256"),
                                       modified_at: blob["modified_at"])]
        end
      rescue JSON::ParserError, KeyError
        raise Error, "cannot list blobs: unexpected response from server #{@url}"
      end

      def stored_sha256(body)
        sha256 = JSON.parse(body.to_s)["sha256"]
        sha256 if sha256.is_a?(String)
      rescue JSON::ParserError, NoMethodError, TypeError
        nil
      end

      def close_quietly
        close
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
