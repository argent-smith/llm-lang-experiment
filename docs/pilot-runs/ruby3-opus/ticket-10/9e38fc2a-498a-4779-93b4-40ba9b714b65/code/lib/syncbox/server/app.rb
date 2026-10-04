# frozen_string_literal: true

require "json"
require "uri"

module Syncbox
  module Server
    # Rack application implementing the Syncbox HTTP API.
    class App
      BLOB_PREFIX = "/blobs/"

      # Response body streaming an open file in chunks; closes it when done.
      class FileBody
        def initialize(file)
          @file = file
        end

        def each
          while (chunk = @file.read(Store::CHUNK_SIZE))
            yield chunk
          end
        end

        def close
          @file.close
        end
      end

      def initialize(config)
        @config = config
        @store = Store.new(config.data_dir)
      end

      def call(env)
        # Request paths are raw bytes and may be anything a client sent.
        path = env["PATH_INFO"].to_s.b
        method = env["REQUEST_METHOD"]

        if path == "/healthz"
          return method_not_allowed("GET, HEAD") unless %w[GET HEAD].include?(method)

          text(200, "ok\n")
        elsif path == "/blobs"
          return method_not_allowed("GET, HEAD") unless %w[GET HEAD].include?(method)

          json(200, @store.list)
        elsif path.start_with?(BLOB_PREFIX) && method == "PUT"
          put_blob(path.delete_prefix(BLOB_PREFIX), env["rack.input"])
        elsif path.start_with?(BLOB_PREFIX) && %w[GET HEAD].include?(method)
          get_blob(path.delete_prefix(BLOB_PREFIX))
        elsif path.start_with?(BLOB_PREFIX) && method == "DELETE"
          delete_blob(path.delete_prefix(BLOB_PREFIX))
        else
          text(404, "not found\n")
        end
      end

      private

      def put_blob(raw_key, input)
        json(201, @store.put(decode_key(raw_key), input))
      rescue InvalidKeyError => e
        text(400, "invalid key: #{e.message}\n")
      end

      def get_blob(raw_key)
        file = @store.open(decode_key(raw_key))
        return text(404, "not found\n") unless file

        headers = { "content-type" => "application/octet-stream", "content-length" => file.size.to_s }
        [200, headers, FileBody.new(file)]
      rescue InvalidKeyError => e
        text(400, "invalid key: #{e.message}\n")
      end

      def delete_blob(raw_key)
        return text(404, "not found\n") unless @store.delete(decode_key(raw_key))

        [204, {}, []]
      rescue InvalidKeyError => e
        text(400, "invalid key: #{e.message}\n")
      end

      # Percent-decodes the key part of the path ("+" stays literal).
      def decode_key(raw_key)
        URI.decode_uri_component(raw_key, Encoding::BINARY)
      rescue ArgumentError
        raise InvalidKeyError, "malformed percent-encoding"
      end

      def text(status, body, headers = {})
        [status, { "content-type" => "text/plain; charset=utf-8" }.merge(headers), [body]]
      end

      def json(status, data)
        [status, { "content-type" => "application/json" }, [JSON.generate(data)]]
      end

      def method_not_allowed(allow)
        text(405, "method not allowed\n", "allow" => allow)
      end
    end
  end
end
