# frozen_string_literal: true

require "json"
require "rack"

module Syncbox
  # Rack-приложение с HTTP API Syncbox.
  #
  # В этом тикете реализован только GET /healthz; таблица маршрутов
  # устроена так, чтобы /blobs и /blobs/{key} добавлялись одной строкой.
  class App
    Route = Struct.new(:method, :pattern, :handler)

    JSON_HEADERS = { "content-type" => "application/json; charset=utf-8" }.freeze

    def initialize(config)
      @config = config
      @routes = [
        Route.new("GET", %r{\A/healthz/?\z}, :healthz)
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
    rescue StandardError => e
      warn "#{e.class}: #{e.message}\n  #{e.backtrace&.first(5)&.join("\n  ")}"
      finish(method, json(500, { "error" => "internal_error" }))
    end

    # GET /healthz — проверка живости.
    def healthz(_request, _match)
      json(200, { "status" => "ok" })
    end

    private

    def json(status, payload, extra_headers = {})
      [status, JSON_HEADERS.merge(extra_headers), [JSON.generate(payload)]]
    end

    # HEAD — как GET, но без тела.
    def finish(method, response)
      status, headers, body = response
      body = [] if method == "HEAD"
      [status, headers, body]
    end
  end
end
