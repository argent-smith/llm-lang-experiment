# frozen_string_literal: true

module Syncbox
  module Client
    # Glue between the command line and the commands: parses options,
    # dispatches the subcommand and maps failures to exit codes.
    class Runner
      EXIT_OK = 0
      EXIT_FAILURE = 1
      EXIT_USAGE = 2
      EXIT_INTERRUPTED = 130

      def initialize(argv, env: ENV, out: $stdout, err: $stderr)
        @argv = argv
        @env = env
        @out = out
        @err = err
      end

      def run
        options = Options.parse(@argv, env: @env)
        api = Api.new(options.server)
        case options.command
        when "push"
          Push.new(dir: options.dir, api: api, out: @out, err: @err).call
        when "pull"
          Pull.new(dir: options.dir, api: api, out: @out, err: @err).call
        when "status"
          Status.new(dir: options.dir, api: api, out: @out, err: @err).call
        when "sync"
          Sync.new(dir: options.dir, api: api, server: options.server.to_s, out: @out, err: @err).call
        else
          raise Options::Error, "unknown command #{options.command.inspect}"
        end
        EXIT_OK
      rescue Options::HelpRequested => e
        @out.puts e.message
        EXIT_OK
      rescue Options::Error => e
        @err.puts "syncbox: #{e.message}"
        @err.puts Options.usage
        EXIT_USAGE
      rescue Api::Error, LocalTree::Error, Transfer::Error, Sync::Error, SyncState::Error, SystemCallError => e
        @err.puts "syncbox: #{e.message}"
        EXIT_FAILURE
      rescue Interrupt
        @err.puts "syncbox: interrupted"
        EXIT_INTERRUPTED
      end
    end
  end
end
