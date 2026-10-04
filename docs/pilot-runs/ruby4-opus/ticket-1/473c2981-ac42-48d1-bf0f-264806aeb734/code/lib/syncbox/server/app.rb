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
        elsif path.start_with?(BLOB_PREFIX) && env["REQUEST_METHOD"] == "PUT"
          put_blob(env, path.delete_prefix(BLOB_PREFIX))
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

      def put_blob(env, raw_key)
        key = decode_path(raw_key)
        return text(400, "invalid key\n") unless key

        json(201, @storage.put(key, env["rack.input"]))
      rescue Storage::InvalidKey
        text(400, "invalid key\n")
      end

      # Percent-decodes the key part of the request path (the client encodes
      # "/" inside a key either literally or as %2F). Returns nil for a
      # malformed escape; the result may still be invalid UTF-8, which
      # Storage rejects.
      def decode_path(raw)
        return nil if raw.match?(/%(?!\h\h)/)

        raw.b.gsub(/%\h\h/) { |escape| escape[1, 2].hex.chr }.force_encoding(Encoding::UTF_8)
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
    end
  end
end
