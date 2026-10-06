# frozen_string_literal: true

require "digest"
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
    #
    # Every network operation has an explicit timeout (OPEN_TIMEOUT,
    # READ_TIMEOUT, WRITE_TIMEOUT), so a server that accepts connections but
    # never answers, a black-holed address or a name that does not resolve
    # ends in an Unreachable error instead of a hang. Opening a connection
    # covers name resolution and the TCP handshake together (TCPSocket's
    # open_timeout); reading and writing are bounded per wait, so a large
    # body that keeps flowing is never cut off, while one that stalls is.
    class Api
      class Error < Client::Error; end

      # The server could not be reached, the connection broke or a timeout
      # expired. The message names the server, the cause and the request.
      class Unreachable < Error
        attr_reader :cause

        def initialize(message, cause: nil)
          super(message)
          @cause = cause
        end

        def timeout?
          cause.is_a?(Timeout::Error)
        end
      end

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

      # A downloaded body could not be written to the local file (disk full,
      # permissions) — a local problem, not a network one.
      class WriteError < Error; end

      RemoteBlob = Struct.new(:key, :size, :sha256, :modified_at, keyword_init: true)
      PutResult = Struct.new(:key, :size, :sha256, keyword_init: true)
      GetResult = Struct.new(:key, :size, :sha256, keyword_init: true)

      SHA256_HEX = /\A[0-9a-f]{64}\z/
      OCTET_STREAM = "application/octet-stream"

      NETWORK_ERRORS = [
        SocketError, SystemCallError, IOError, EOFError, Timeout::Error,
        Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Net::ProtocolError, OpenSSL::SSL::SSLError
      ].freeze

      # Seconds. Opening covers name resolution and the TCP connect; read and
      # write are per wait (the time between two chunks), not per request.
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60
      WRITE_TIMEOUT = 60

      attr_reader :base_url, :open_timeout, :read_timeout, :write_timeout

      # +base_url+ is a URI::HTTP as produced by Options (no trailing slash).
      # The timeouts are fixed for the CLI (see the constants); the keywords
      # exist so that tests can shorten them.
      def initialize(base_url, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT)
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

      # GET /blobs/{key}, streaming the body into the file at +path+ (created
      # or truncated, flushed and fsynced) and hashing it on the way. Returns
      # a GetResult with the bytes received and their SHA-256, so the caller
      # can check them against the listing. A 404 is an HttpError like any
      # other unexpected status; nothing but the file at +path+ is touched.
      def get(key, path)
        request_path = blob_path(key)
        received = nil
        response = request(request_path) do
          # A fresh (truncated) file for every attempt: a retried request
          # starts the body over, and so must the file.
          file = File.open(path, "wb")
          req = Net::HTTP::Get.new(request_path)
          [req, file, ->(res) { received = receive_body(key, res, file, path) if res.code == "200" }]
        end
        raise HttpError.new("GET", request_path, response) unless response.code == "200"

        received
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

      # Sends the request built by the block and returns the response. The
      # block returns a request, [request, io_to_close] or
      # [request, io_to_close, on_response]; +on_response+ is called with the
      # response while its body is still on the wire, so it can stream the
      # body (a body it does not read is drained afterwards). Network failures
      # become Unreachable; a failure on a connection that already served a
      # request is retried once on a fresh connection, since the server may
      # simply have closed an idle keep-alive connection. A timeout is never
      # retried: the server was reached and did not answer in time, and
      # waiting as long again would only double the delay. The block is
      # called again for the retry, so each attempt starts from scratch.
      def request(path)
        attempts = 0
        loop do
          attempts += 1
          reused = @requests_on_connection.positive?
          # Outside the rescue below: a local failure while building the
          # request (e.g. the file vanished) is not a network problem.
          req, io, on_response = yield
          begin
            response = http.request(req) { |res| on_response&.call(res) }
            @requests_on_connection += 1
            return response
          rescue *NETWORK_ERRORS => e
            close
            next if reused && attempts == 1 && !e.is_a?(Timeout::Error)

            raise Unreachable.new("cannot reach server at #{@base_url}: #{describe(e)} (#{req.method} #{path})", cause: e)
          rescue Error
            # Raised by on_response (e.g. WriteError) with the body possibly
            # unread: the connection is not reusable, drop it.
            close
            raise
          ensure
            # A download file that failed to flush has already been reported
            # (WriteError); closing it would only raise the same error again.
            begin
              io&.close
            rescue IOError, SystemCallError
              nil
            end
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

      # The cause of a network failure in words a user can act on. Net::HTTP's
      # own messages range from "Failed to open TCP connection to h:p
      # (Connection refused - connect(2) for "h" port p)" to "Net::ReadTimeout
      # with #<TCPSocket:(closed)>", which does not even mention time.
      def describe(error)
        where = "#{@base_url.host}:#{@base_url.port}"
        case error
        when Net::OpenTimeout
          "connection to #{where} timed out after #{@open_timeout}s"
        when Net::ReadTimeout
          "no response from #{where} within #{@read_timeout}s (read timeout)"
        when Net::WriteTimeout
          "request to #{where} could not be sent within #{@write_timeout}s (write timeout)"
        when Timeout::Error
          "timed out (#{error.message})"
        when SocketError
          "cannot resolve host name #{@base_url.host.inspect} (#{os_error_text(error)})"
        when Errno::ECONNREFUSED
          "connection refused by #{where} (is the server running there?)"
        when Errno::ECONNRESET
          "connection reset by #{where}"
        when Errno::EPIPE
          "connection closed by #{where} while the request was being sent"
        when Errno::EHOSTUNREACH, Errno::ENETUNREACH
          "#{where} is not reachable (#{os_error_text(error)})"
        when EOFError
          "connection closed by #{where} before the response was complete"
        when OpenSSL::SSL::SSLError
          "TLS handshake with #{where} failed (#{error.message})"
        when SystemCallError
          os_error_text(error)
        else
          "#{error.class}: #{error.message}"
        end
      end

      # The operating system's text alone. Net::HTTP wraps connect errors as
      # "Failed to open TCP connection to h:p (Connection refused - connect(2)
      # for "h" port p)" and resolver errors as "... (getaddrinfo: Name or
      # service not known)"; Ruby itself appends " @ rb_sysopen - path".
      def os_error_text(error)
        text = error.message
        text = Regexp.last_match(1) if text =~ /\A.*?\(((?:[^()]|\([^()]*\))*)\)\z/m
        text.sub(/\Agetaddrinfo: /, "").sub(/ - \w+\(\d\) for .*\z/m, "").sub(/ @ \w+ - .*\z/m, "")
      end

      # Streams the body of a 200 response into +file+, hashing it. Only the
      # file operations are wrapped: a socket failure raised by read_body must
      # stay a network error (see NETWORK_ERRORS), a disk failure must not.
      def receive_body(key, response, file, path)
        digest = Digest::SHA256.new
        size = 0
        response.read_body do |chunk|
          write_chunk(file, chunk, path)
          digest << chunk
          size += chunk.bytesize
        end
        begin
          file.flush
          file.fsync
        rescue SystemCallError, IOError => e
          raise WriteError, "cannot write #{path}: #{e.message}"
        end
        GetResult.new(key: key, size: size, sha256: digest.hexdigest)
      end

      def write_chunk(file, chunk, path)
        file.write(chunk)
      rescue SystemCallError, IOError => e
        raise WriteError, "cannot write #{path}: #{e.message}"
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
