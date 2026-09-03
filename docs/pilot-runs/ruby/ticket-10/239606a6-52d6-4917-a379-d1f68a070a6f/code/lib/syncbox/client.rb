require "net/http"
require "uri"
require "json"
require "erb"
require "timeout"

module Syncbox
  # Thin HTTP transport over the Syncbox server API (GET /blobs, PUT/GET
  # /blobs/{key}). Knows nothing about local files or diffing — that's
  # Push/Pull's job — so it can be reused by the future status/sync
  # commands without change.
  class Client
    # Raised when the server can't be reached at all (connection refused,
    # DNS failure, timeout) — as opposed to ServerError, raised when it
    # responds but not with success.
    class ConnectionError < StandardError; end
    class ServerError < StandardError; end

    NETWORK_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::ETIMEDOUT,
      Errno::ECONNRESET,
      SocketError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      Timeout::Error,
      EOFError
    ].freeze

    def initialize(server:)
      @base_uri = URI.parse(server)
      unless @base_uri.is_a?(URI::HTTP) && @base_uri.host
        raise ArgumentError, "invalid --server URL: #{server.inspect}"
      end
    end

    # Returns { key => sha256 } for every blob currently on the server.
    def list_blobs
      list_blobs_meta.transform_values { |meta| meta.fetch(:sha256) }
    end

    # Like list_blobs, but keeps modified_at (and size) too -- sync needs
    # modified_at for its conflict-resolution rule, which plain sha256
    # comparison can't decide.
    def list_blobs_meta
      response = get("/blobs")
      raise_unless_success(response, "GET /blobs")

      JSON.parse(response.body).each_with_object({}) do |entry, blobs|
        blobs[entry.fetch("key")] = {
          sha256: entry.fetch("sha256"),
          modified_at: entry.fetch("modified_at"),
          size: entry.fetch("size")
        }
      end
    end

    def put_blob(key, body)
      response = put(blob_path(key), body)
      raise_unless_success(response, "PUT /blobs/#{key}")

      JSON.parse(response.body)
    end

    # Returns the raw bytes of the blob stored under `key`.
    def get_blob(key)
      response = get(blob_path(key))
      raise_unless_success(response, "GET /blobs/#{key}")

      response.body.to_s
    end

    private

    # Percent-encodes each path segment independently so a key like
    # "docs/readme.txt" round-trips through the URL as two segments, not
    # one with an encoded slash.
    def blob_path(key)
      "/blobs/#{key.split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')}"
    end

    def get(path)
      execute(Net::HTTP::Get.new(uri_for(path)))
    end

    def put(path, body)
      request = Net::HTTP::Put.new(uri_for(path))
      request.body = body
      execute(request)
    end

    def uri_for(path)
      URI.join(@base_uri, path)
    end

    def execute(request)
      Net::HTTP.start(
        @base_uri.host,
        @base_uri.port,
        use_ssl: @base_uri.scheme == "https",
        open_timeout: 10,
        read_timeout: 30
      ) { |http| http.request(request) }
    rescue *NETWORK_ERRORS => e
      raise ConnectionError, "cannot reach server at #{@base_uri}: #{e.message}"
    end

    def raise_unless_success(response, what)
      return if response.is_a?(Net::HTTPSuccess)

      raise ServerError, "#{what} failed: #{response.code} #{response.message}"
    end
  end
end
