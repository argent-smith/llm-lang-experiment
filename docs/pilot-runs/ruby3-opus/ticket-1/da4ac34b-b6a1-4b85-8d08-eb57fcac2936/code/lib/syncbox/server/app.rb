# frozen_string_literal: true

module Syncbox
  module Server
    # Rack application implementing the Syncbox HTTP API.
    class App
      def initialize(config)
        @config = config
      end

      def call(env)
        case env["PATH_INFO"]
        when "/healthz"
          return method_not_allowed("GET, HEAD") unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

          text(200, "ok\n")
        else
          text(404, "not found\n")
        end
      end

      private

      def text(status, body, headers = {})
        [status, { "content-type" => "text/plain; charset=utf-8" }.merge(headers), [body]]
      end

      def method_not_allowed(allow)
        text(405, "method not allowed\n", "allow" => allow)
      end
    end
  end
end
