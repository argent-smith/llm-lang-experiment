# frozen_string_literal: true

module Syncbox
  module Client
    # Glue between the command line and the commands: parses options,
    # dispatches the subcommand and maps outcomes to exit codes.
    #
    #   0  success: the command ran to the end and every file went through
    #   1  failure: the command could not do its job — the server is
    #      unreachable (connection refused, unknown host, timeout) or stopped
    #      answering mid-run, it answered outside the contract, the
    #      directory is missing, the sync state is corrupt or cannot be saved
    #   2  usage error (bad arguments, missing --server)
    #   3  partial failure: the command ran to the end, but one or more files
    #      failed and are listed on stderr; the others were processed
    #   130 interrupted
    #
    # The spec asks for "non-zero" in the last two failure cases; 1 and 3 keep
    # "nothing could be done" apart from "most of it was done" for scripts.
    class Runner
      EXIT_OK = 0
      EXIT_FAILURE = 1
      EXIT_USAGE = 2
      EXIT_PARTIAL = 3
      EXIT_INTERRUPTED = 130

      # +build_api+ turns the server URL (a URI) into the Api the commands
      # use; tests pass one that shortens the timeouts.
      def initialize(argv, env: ENV, out: $stdout, err: $stderr, build_api: Api.method(:new))
        @argv = argv
        @env = env
        @out = out
        @err = err
        @build_api = build_api
      end

      def run
        options = Options.parse(@argv, env: @env)
        api = @build_api.call(options.server)
        result = case options.command
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
        result.failed.positive? ? EXIT_PARTIAL : EXIT_OK
      rescue Options::HelpRequested => e
        @out.puts e.message
        EXIT_OK
      rescue Options::Error => e
        @err.puts "syncbox: #{e.message}"
        @err.puts Options.usage
        EXIT_USAGE
      rescue Client::Error, SystemCallError => e
        @err.puts "syncbox: #{e.message}"
        EXIT_FAILURE
      rescue Interrupt
        @err.puts "syncbox: interrupted"
        EXIT_INTERRUPTED
      end
    end
  end
end
