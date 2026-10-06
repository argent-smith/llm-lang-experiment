# frozen_string_literal: true

require "puma"
require "puma/configuration"
require "puma/launcher"

module Syncbox
  module Server
    # Entry point of the syncbox-server executable. Runs in the foreground
    # until SIGTERM/SIGINT, then shuts down gracefully.
    module CLI
      BIND_HOST = "0.0.0.0"
      EXIT_FAILURE = 1
      EXIT_USAGE = 2

      def self.run(argv, env: ENV, out: $stdout, err: $stderr)
        config = Config.parse(argv, env)
        config.prepare_data_dir!
        storage = Storage.new(config.data_dir)
        storage.prepare!
        out.puts "syncbox-server: data directory #{config.data_dir}"
        out.flush
        app = App.new(config, storage: storage)
        Puma::Launcher.new(puma_config(config, app), log_writer: Puma::LogWriter.stdio).run
        0
      rescue Config::HelpRequested
        out.puts Config::USAGE
        0
      rescue Config::Error => e
        err.puts "syncbox-server: #{e.message}", Config::USAGE
        EXIT_USAGE
      rescue Storage::Unusable => e
        err.puts "syncbox-server: #{e.message}"
        EXIT_FAILURE
      rescue SystemCallError => e
        # Most likely the port could not be bound (in use, no permission).
        err.puts "syncbox-server: cannot listen on #{BIND_HOST}:#{config.port}: #{e.message}"
        EXIT_FAILURE
      end

      def self.puma_config(config, app)
        Puma::Configuration.new(config_files: ["-"]) do |c|
          c.app app
          c.bind "tcp://#{BIND_HOST}:#{config.port}"
          c.environment "production"
          c.threads 0, 16
          c.log_requests false
          c.raise_exception_on_sigterm false
          c.tag "syncbox"
        end
      end
    end
  end
end
