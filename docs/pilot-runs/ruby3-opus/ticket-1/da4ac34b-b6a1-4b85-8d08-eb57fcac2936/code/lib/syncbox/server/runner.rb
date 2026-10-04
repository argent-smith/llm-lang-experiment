# frozen_string_literal: true

require "puma"
require "puma/configuration"
require "puma/launcher"
require "puma/log_writer"
require "rack"

module Syncbox
  module Server
    # Boots the Rack app under Puma in the current process (no daemonizing).
    module Runner
      BIND_HOST = "0.0.0.0"

      def self.build_app(config)
        Rack::Builder.app do
          use Rack::Head
          run App.new(config)
        end
      end

      def self.run(config)
        app = build_app(config)
        puma_config = Puma::Configuration.new({}, {}, {}) do |c|
          c.bind "tcp://#{BIND_HOST}:#{config.port}"
          c.app app
          c.environment "production"
          c.workers 0
          c.threads 0, 16
          c.log_requests false
          # Exit with status 0 after a graceful shutdown on SIGTERM.
          c.raise_exception_on_sigterm false
        end
        Puma::Launcher.new(puma_config, log_writer: Puma::LogWriter.stdio).run
      end
    end
  end
end
