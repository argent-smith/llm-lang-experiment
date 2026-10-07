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
            blob(method, decode_key(path.byteslice(BLOBS_PREFIX.bytesize..)), env)
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

      def blob(method, key, env)
        case method
        when "GET", "HEAD" then get_blob(key)
        when "PUT" then put_blob(key, env["rack.input"])
        when "DELETE" then delete_blob(key)
        else method_not_allowed("GET, HEAD, PUT, DELETE")
        end
      end

      def put_blob(key, input)
        meta = store.put(key, input)
        json(201, key: meta.key, sha256: meta.sha256, size: meta.size)
      rescue BlobStore::InvalidKey => e
        bad_request(e.message)
      end

      def get_blob(key)
        store.open(key) do |file, size|
          [200, { "content-type" => OCTET_STREAM, "content-length" => size.to_s }, [file.read]]
        end
      rescue BlobStore::InvalidKey => e
        bad_request(e.message)
      rescue BlobStore::NotFound
        not_found
      end

      def delete_blob(key)
        store.delete(key)
        [204, {}, []]
      rescue BlobStore::InvalidKey => e
        bad_request(e.message)
      rescue BlobStore::NotFound
        not_found
      end

      # PATH_INFO arrives percent-encoded (Puma and Rack::MockRequest alike);
      # the key is the decoded remainder after "/blobs/". '+' is kept literal
      # (it is not a space in a path).
      def decode_key(raw)
        Rack::Utils.unescape_path(raw).dup.force_encoding(Encoding::UTF_8)
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
