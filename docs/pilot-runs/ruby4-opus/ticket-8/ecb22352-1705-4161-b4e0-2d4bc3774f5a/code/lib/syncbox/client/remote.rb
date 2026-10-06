# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

module Syncbox
  module Client
    # The server's HTTP API (syncbox-openapi.yaml), over one keep-alive
    # connection. Network failures and unexpected responses raise Error.
    class Remote
      # Metadata of a stored blob as listed by GET /blobs.
      Blob = Data.define(:key, :size, :sha256)

      # The blob asked for is not (or no longer) stored on the server.
      class NotFound < Error; end

      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 120
      WRITE_TIMEOUT = 120

      NETWORK_ERRORS = [
        SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
        Net::HTTPBadResponse, Net::ProtocolError
      ].freeze

      # Bytes percent-encoded in a key: all but unreserved characters and "/",
      # which stays literal as the separator of the key's segments.
      KEY_UNSAFE = %r{[^A-Za-z0-9\-._~/]}n

      def self.open(url)
        remote = new(url)
        yield remote
      ensure
        remote&.close
      end

      def initialize(url)
        @url = url
        @base_path = url.path.sub(%r{/+\z}, "")
        @http = Net::HTTP.new(url.host, url.port)
        @http.use_ssl = url.scheme == "https"
        @http.open_timeout = OPEN_TIMEOUT
        @http.read_timeout = READ_TIMEOUT
        @http.write_timeout = WRITE_TIMEOUT
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
      def put(key, io)
        request = Net::HTTP::Put.new(blob_path(key))
        request["content-type"] = "application/octet-stream"
        # Chunked rather than a Content-Length taken up front: a file that
        # grows or shrinks while being sent still makes a well-formed request.
        request["transfer-encoding"] = "chunked"
        request.body_stream = io
        expect(request(request, "upload #{key}"), Net::HTTPCreated, "upload #{key}")
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
        @http.start unless @http.started?
        @http.request(request, &)
      rescue *NETWORK_ERRORS => e
        close_quietly
        raise Error, "cannot #{action}: server #{@url} is unreachable: #{e.message}"
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
          [blob.fetch("key"), Blob.new(key: blob.fetch("key"), size: blob.fetch("size"), sha256: blob.fetch("sha256"))]
        end
      rescue JSON::ParserError, KeyError
        raise Error, "cannot list blobs: unexpected response from server #{@url}"
      end

      def close_quietly
        close
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
