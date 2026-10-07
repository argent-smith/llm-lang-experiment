# frozen_string_literal: true

module Syncbox
  module Server
    # Rack application implementing the HTTP API from syncbox-openapi.yaml.
    class App
      TEXT = { "content-type" => "text/plain; charset=utf-8" }.freeze

      def initialize(config)
        @config = config
      end

      def call(env)
        case env["PATH_INFO"]
        when "/healthz"
          healthz(env)
        else
          text(404, "not found\n")
        end
      end

      private

      def healthz(env)
        return method_not_allowed("GET, HEAD") unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        text(200, "ok\n")
      end

      def method_not_allowed(allow)
        status, headers, body = text(405, "method not allowed\n")
        [status, headers.merge("allow" => allow), body]
      end

      def text(status, body)
        [status, TEXT.dup, [body]]
      end
    end
  end
end
