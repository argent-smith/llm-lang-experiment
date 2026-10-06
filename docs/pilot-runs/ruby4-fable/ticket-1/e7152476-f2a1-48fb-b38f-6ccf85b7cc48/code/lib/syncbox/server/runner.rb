# frozen_string_literal: true

require "fileutils"

module Syncbox
  module Server
    # Glue between the CLI and Puma: parses config, prepares the data dir,
    # boots the HTTP server in the foreground and maps failures to exit codes.
    class Runner
      EXIT_OK = 0
      EXIT_FAILURE = 1
      EXIT_USAGE = 2

      def initialize(argv, env: ENV, out: $stdout, err: $stderr)
        @argv = argv
        @env = env
        @out = out
        @err = err
      end

      def run
        config = Config.parse(@argv, env: @env)
        prepare_data_dir(config.data_dir)
        serve(config)
        EXIT_OK
      rescue Config::HelpRequested => e
        @out.puts e.message
        EXIT_OK
      rescue Config::Error => e
        @err.puts "syncbox-server: #{e.message}"
        @err.puts Config.usage
        EXIT_USAGE
      rescue SystemCallError => e
        @err.puts "syncbox-server: #{e.message}"
        EXIT_FAILURE
      end

      private

      def prepare_data_dir(dir)
        FileUtils.mkdir_p(dir)
        raise Errno::ENOTDIR, dir unless File.directory?(dir)
        raise Errno::EACCES, "data dir is not writable: #{dir}" unless File.writable?(dir)
      end

      def serve(config)
        require "puma"
        require "puma/configuration"
        require "puma/launcher"
        require "puma/log_writer"

        app = App.new(config)
        puma_config = Puma::Configuration.new do |c|
          c.bind "tcp://#{config.host}:#{config.port}"
          c.app app
          c.environment "production"
          c.threads 1, 16
          c.log_requests false
          # Exit 0 after a graceful stop instead of re-raising the signal.
          c.raise_exception_on_sigterm false
          c.tag "syncbox"
        end

        @out.puts "syncbox-server #{VERSION}: data dir #{config.data_dir}, " \
                  "listening on http://#{config.host}:#{config.port}"
        @out.flush

        log_writer = Puma::LogWriter.new(@out, @err)
        Puma::Launcher.new(puma_config, log_writer: log_writer).run
      end
    end
  end
end
