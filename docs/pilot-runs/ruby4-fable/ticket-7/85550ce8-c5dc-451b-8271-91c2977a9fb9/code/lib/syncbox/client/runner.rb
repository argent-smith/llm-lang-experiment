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

      NOT_IMPLEMENTED = {
        "pull" => "ticket 8",
        "status" => "ticket 9",
        "sync" => "ticket 10"
      }.freeze

      def initialize(argv, env: ENV, out: $stdout, err: $stderr)
        @argv = argv
        @env = env
        @out = out
        @err = err
      end

      def run
        options = Options.parse(@argv, env: @env)
        case options.command
        when "push"
          Push.new(dir: options.dir, api: Api.new(options.server), out: @out, err: @err).call
          EXIT_OK
        else
          not_implemented(options.command)
        end
      rescue Options::HelpRequested => e
        @out.puts e.message
        EXIT_OK
      rescue Options::Error => e
        @err.puts "syncbox: #{e.message}"
        @err.puts Options.usage
        EXIT_USAGE
      rescue Api::Error, LocalTree::Error, Push::Error, SystemCallError => e
        @err.puts "syncbox: #{e.message}"
        EXIT_FAILURE
      rescue Interrupt
        @err.puts "syncbox: interrupted"
        EXIT_INTERRUPTED
      end

      private

      def not_implemented(command)
        @err.puts "syncbox: '#{command}' is not implemented yet (planned for #{NOT_IMPLEMENTED[command]}); " \
                  "only 'push' is available in this version"
        EXIT_FAILURE
      end
    end
  end
end
