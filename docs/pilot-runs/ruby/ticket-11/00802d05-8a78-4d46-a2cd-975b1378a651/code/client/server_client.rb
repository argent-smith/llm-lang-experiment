require "net/http"
require "uri"
require "json"

module Syncbox
  # Talks to the Syncbox HTTP API (see SYNCBOX-SPEC.md / syncbox-openapi.yaml).
  class ServerClient
    ConnectionError = Class.new(StandardError)
    RequestError = Class.new(StandardError)

    def initialize(base_url)
      @base_uri = URI.parse(base_url)
      unless @base_uri.is_a?(URI::HTTP) && @base_uri.host
        raise ArgumentError, "invalid --server URL: #{base_url}"
      end
    end

    def list_blobs
      response = perform(Net::HTTP::Get.new(uri_for("/blobs")))
      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError, "GET /blobs failed: HTTP #{response.code}"
      end

      JSON.parse(response.body)
    end

    def get_blob(key)
      response = perform(Net::HTTP::Get.new(uri_for("/blobs/#{escape_key(key)}")))
      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError, "GET /blobs/#{key} failed: HTTP #{response.code}"
      end

      response.body.to_s
    end

    def put_blob(key, data)
      req = Net::HTTP::Put.new(uri_for("/blobs/#{escape_key(key)}"))
      req.body = data
      req["Content-Type"] = "application/octet-stream"

      response = perform(req)
      unless response.is_a?(Net::HTTPCreated)
        raise RequestError, "PUT /blobs/#{key} failed: HTTP #{response.code}"
      end

      response
    end

    private

    def uri_for(path)
      uri = @base_uri.dup
      base_path = uri.path.to_s.chomp("/")
      uri.path = "#{base_path}#{path}"
      uri
    end

    def perform(req)
      Net::HTTP.start(
        @base_uri.host, @base_uri.port,
        use_ssl: @base_uri.scheme == "https",
        open_timeout: 10, read_timeout: 60
      ) { |http| http.request(req) }
    rescue Net::OpenTimeout
      raise ConnectionError, "cannot reach server at #{@base_uri}: connection timed out"
    rescue Net::ReadTimeout
      raise ConnectionError, "cannot reach server at #{@base_uri}: timed out waiting for a response"
    rescue SocketError => e
      raise ConnectionError, "cannot reach server at #{@base_uri}: host could not be resolved (#{e.message})"
    rescue Errno::ECONNREFUSED
      raise ConnectionError, "cannot reach server at #{@base_uri}: connection refused"
    rescue SystemCallError, EOFError => e
      raise ConnectionError, "cannot reach server at #{@base_uri}: #{e.message}"
    end

    # Percent-encodes each path segment individually (preserving '/' as the
    # segment separator), so a key with nested directories still maps to a
    # single splat-matched path on the server (see server/app.rb).
    def escape_key(key)
      key.split("/", -1).map { |segment| escape_segment(segment) }.join("/")
    end

    def escape_segment(segment)
      segment.b.each_byte.map do |byte|
        chr = byte.chr
        chr =~ /[A-Za-z0-9\-._~]/ ? chr : format("%%%02X", byte)
      end.join
    end
  end
end
