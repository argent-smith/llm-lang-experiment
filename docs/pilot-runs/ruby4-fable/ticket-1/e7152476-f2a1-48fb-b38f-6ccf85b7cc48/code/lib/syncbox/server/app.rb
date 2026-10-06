# frozen_string_literal: true

require "json"

module Syncbox
  module Server
    # Rack application. Ticket 1 only exposes GET /healthz; blob endpoints
    # arrive in later tickets and will be routed from #call as well.
    class App
      JSON_HEADERS = { "content-type" => "application/json" }.freeze

      attr_reader :config

      def initialize(config)
        @config = config
      end

      def call(env)
        path = env["PATH_INFO"]
        method = env["REQUEST_METHOD"]

        case path
        when "/healthz"
          healthz(method)
        else
          not_found
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

      def not_found
        json(404, error: "not found")
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
