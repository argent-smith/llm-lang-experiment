# frozen_string_literal: true

require "json"
require "rack"

module Syncbox
  # Rack-приложение с HTTP API Syncbox: /healthz, /blobs, /blobs/{key}.
  class App
    Route = Struct.new(:method, :pattern, :handler)

    JSON_HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze
    OCTET_STREAM = "application/octet-stream"

    BLOB_KEY_PATTERN = %r{\A/blobs/(.*)\z}m

    def initialize(config)
      @config = config
      @store = Store.new(config.data_dir)
      @routes = [
        Route.new("GET", %r{\A/healthz/?\z}, :healthz),
        Route.new("GET", %r{\A/blobs\z}, :list_blobs),
        Route.new("GET", BLOB_KEY_PATTERN, :get_blob),
        Route.new("PUT", BLOB_KEY_PATTERN, :put_blob),
        Route.new("DELETE", BLOB_KEY_PATTERN, :delete_blob)
      ]
    end

    def call(env)
      request = Rack::Request.new(env)
      method = request.request_method
      lookup_method = method == "HEAD" ? "GET" : method
      path = request.path_info

      allowed = []
      @routes.each do |route|
        match = route.pattern.match(path)
        next unless match

        allowed << route.method
        next unless route.method == lookup_method

        return finish(method, public_send(route.handler, request, match))
      end

      return finish(method, json(405, { "error" => "method_not_allowed" }, "allow" => allowed.uniq.join(", "))) unless allowed.empty?

      finish(method, json(404, { "error" => "not_found" }))
    rescue Store::InvalidKey => e
      finish(method, json(400, { "error" => "invalid_key", "message" => e.message }))
    rescue Store::NotFound
      finish(method, json(404, { "error" => "not_found" }))
    rescue StandardError => e
      warn "#{e.class}: #{e.message}\n  #{e.backtrace&.first(5)&.join("\n  ")}"
      finish(method, json(500, { "error" => "internal_error" }))
    end

    # GET /healthz — проверка живости.
    def healthz(_request, _match)
      json(200, { "status" => "ok" })
    end

    # GET /blobs — список всех блобов с метаданными.
    def list_blobs(_request, _match)
      json(200, @store.list)
    end

    # GET /blobs/{key} — содержимое блоба.
    def get_blob(_request, match)
      size, body = @store.open(decode_key(match[1]))
      [200, { "content-type" => OCTET_STREAM, "content-length" => size.to_s }, body]
    end

    # PUT /blobs/{key} — сохранить сырые байты тела запроса.
    def put_blob(request, match)
      json(201, @store.put(decode_key(match[1]), request.body))
    end

    # DELETE /blobs/{key} — удалить блоб.
    def delete_blob(_request, match)
      @store.delete(decode_key(match[1]))
      [204, {}, []]
    end

    private

    # key приходит в PATH_INFO percent-encoded; декодируем, не трогая `/`.
    def decode_key(raw)
      Rack::Utils.unescape_path(raw)
    rescue ArgumentError => e
      raise Store::InvalidKey, "key cannot be decoded: #{e.message}"
    end

    def json(status, payload, extra_headers = {})
      [status, JSON_HEADERS.merge(extra_headers), [JSON.generate(payload)]]
    end

    # HEAD — как GET, но без тела.
    def finish(method, response)
      status, headers, body = response
      if method == "HEAD"
        body.close if body.respond_to?(:close)
        body = []
      end
      [status, headers, body]
    end
  end
end
