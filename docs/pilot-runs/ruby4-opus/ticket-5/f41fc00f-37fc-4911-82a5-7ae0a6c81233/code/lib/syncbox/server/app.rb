# frozen_string_literal: true

require "json"

module Syncbox
  module Server
    # Rack application implementing the HTTP API from syncbox-openapi.yaml.
    class App
      TEXT = { "content-type" => "text/plain; charset=utf-8" }.freeze
      JSON_TYPE = { "content-type" => "application/json" }.freeze
      BLOB_PREFIX = "/blobs/"

      def initialize(config)
        @config = config
        @storage = Storage.new(config.data_dir)
      end

      def call(env)
        path = env["PATH_INFO"]
        if path == "/healthz"
          healthz(env)
        elsif path == "/blobs"
          list_blobs(env)
        elsif path.start_with?(BLOB_PREFIX)
          blob(env, path.delete_prefix(BLOB_PREFIX))
        else
          text(404, "not found\n")
        end
      end

      private

      def healthz(env)
        return method_not_allowed("GET, HEAD") unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        text(200, "ok\n")
      end

      def list_blobs(env)
        return method_not_allowed("GET, HEAD") unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        json(200, @storage.list)
      end

      def blob(env, raw_key)
        case env["REQUEST_METHOD"]
        when "GET", "HEAD" then get_blob(raw_key)
        when "PUT" then put_blob(env, raw_key)
        when "DELETE" then delete_blob(raw_key)
        else method_not_allowed("GET, HEAD, PUT, DELETE")
        end
      end

      def get_blob(raw_key)
        key = decode_path(raw_key)
        return text(400, "invalid key\n") unless key

        file = @storage.open(key)
        return text(404, "not found\n") unless file

        headers = { "content-type" => "application/octet-stream", "content-length" => file.size.to_s }
        [200, headers, FileBody.new(file)]
      rescue Storage::InvalidKey
        text(400, "invalid key\n")
      end

      def put_blob(env, raw_key)
        key = decode_path(raw_key)
        return text(400, "invalid key\n") unless key

        json(201, @storage.put(key, env["rack.input"]))
      rescue Storage::InvalidKey
        text(400, "invalid key\n")
      end

      def delete_blob(raw_key)
        key = decode_path(raw_key)
        return text(400, "invalid key\n") unless key
        return text(404, "not found\n") unless @storage.delete(key)

        [204, {}, []]
      rescue Storage::InvalidKey
        text(400, "invalid key\n")
      end

      # Percent-decodes the key part of the request path (the client encodes
      # "/" inside a key either literally or as %2F). Returns nil for a
      # malformed escape; the result may still be invalid UTF-8, which
      # Storage rejects. Works on the bytes, whatever encoding the server
      # tagged the path with.
      def decode_path(raw)
        raw = raw.b
        return nil if raw.match?(/%(?!\h\h)/)

        raw.gsub(/%\h\h/) { |escape| escape[1, 2].hex.chr }.force_encoding(Encoding::UTF_8)
      end

      def method_not_allowed(allow)
        status, headers, body = text(405, "method not allowed\n")
        [status, headers.merge("allow" => allow), body]
      end

      def json(status, data)
        [status, JSON_TYPE.dup, [JSON.generate(data)]]
      end

      def text(status, body)
        [status, TEXT.dup, [body]]
      end

      # Streams an already opened blob in chunks. Deliberately has no
      # #to_path: the server would reopen the file by name and could send a
      # blob replaced in the meantime under the old content-length.
      class FileBody
        def initialize(file)
          @file = file
        end

        def each
          while (chunk = @file.read(Storage::CHUNK_SIZE))
            yield chunk
          end
        end

        def close
          @file.close
        end
      end
    end
  end
end
