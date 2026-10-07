# frozen_string_literal: true

require "json"
require "rack/utils"

module Syncbox
  module Server
    # Rack application: routes /healthz, /blobs and /blobs/{key} (see
    # syncbox-openapi.yaml) onto a BlobStore rooted at config.data_dir.
    class App
      JSON_HEADERS = { "content-type" => "application/json" }.freeze
      OCTET_STREAM = "application/octet-stream"
      BLOBS_PREFIX = "/blobs/"
      BLOB_METHODS = "GET, HEAD, PUT, DELETE"

      attr_reader :config, :store

      def initialize(config, store: BlobStore.new(config.data_dir))
        @config = config
        @store = store
      end

      def call(env)
        path = env["PATH_INFO"]
        method = env["REQUEST_METHOD"]

        case path
        when "/healthz"
          healthz(method)
        when "/blobs"
          list_blobs(method)
        else
          if path.start_with?(BLOBS_PREFIX)
            blob(method, path.byteslice(BLOBS_PREFIX.bytesize..), env)
          else
            not_found
          end
        end
      end

      private

      def healthz(method)
        case method
        when "GET", "HEAD"
          json(200, status: "ok")
        else
          method_not_allowed("GET, HEAD")
        end
      end

      def list_blobs(method)
        case method
        when "GET", "HEAD"
          json(200, store.list.map(&:to_h))
        else
          method_not_allowed("GET, HEAD")
        end
      end

      # /blobs/{key}: the key is validated by the store on every method, and
      # any key that cannot be decoded, is not a safe relative path, or does
      # not resolve inside the storage root answers 400 — never 5xx.
      def blob(method, raw_key, env)
        return method_not_allowed(BLOB_METHODS) unless %w[GET HEAD PUT DELETE].include?(method)

        key = decode_key(raw_key)
        case method
        when "GET", "HEAD" then get_blob(key)
        when "PUT" then put_blob(key, env["rack.input"])
        when "DELETE" then delete_blob(key)
        end
      rescue BlobStore::InvalidKey => e
        bad_request(e.message)
      end

      def put_blob(key, input)
        meta = store.put(key, input)
        json(201, key: meta.key, sha256: meta.sha256, size: meta.size)
      end

      def get_blob(key)
        store.open(key) do |file, size|
          [200, { "content-type" => OCTET_STREAM, "content-length" => size.to_s }, [file.read]]
        end
      rescue BlobStore::NotFound
        not_found
      end

      def delete_blob(key)
        store.delete(key)
        [204, {}, []]
      rescue BlobStore::NotFound
        not_found
      end

      # PATH_INFO arrives percent-encoded (Puma and Rack::MockRequest alike);
      # the key is the decoded remainder after "/blobs/". Decoded exactly once,
      # so "%252e%252e" is the literal name "%2e%2e", not "..". '+' is kept
      # literal (it is not a space in a path). Bytes that do not form valid
      # UTF-8 after decoding are left for BlobStore#validate_key to reject.
      def decode_key(raw)
        Rack::Utils.unescape_path(raw).dup.force_encoding(Encoding::UTF_8)
      rescue ArgumentError, EncodingError => e
        raise BlobStore::InvalidKey, "key cannot be decoded: #{e.message}"
      end

      def not_found
        json(404, error: "not found")
      end

      def bad_request(message)
        json(400, error: "invalid key", detail: message)
      end

      def method_not_allowed(allow)
        json(405, { error: "method not allowed" }, "allow" => allow)
      end

      def json(status, payload, extra_headers = {})
        body = JSON.generate(payload)
        [status, JSON_HEADERS.merge(extra_headers), [body]]
      end
    end
  end
end
