# frozen_string_literal: true

module Syncbox
  module Client
    # Entry point of the syncbox executable.
    #
    # Exit codes: 0 success, 1 failure (the server is unreachable, or any file
    # failed: then a report of every failed file is printed to stderr at the
    # end), 2 invalid arguments, 130 interrupted.
    module CLI
      EXIT_FAILURE = 1
      EXIT_USAGE = 2
      EXIT_INTERRUPTED = 130

      # +timeouts+ go to Remote (open_timeout: and so on); there is no flag
      # for them, they are only for tests.
      def self.run(argv, env: ENV, out: $stdout, err: $stderr, timeouts: {})
        config = Config.parse(argv, env)
        Remote.open(config.server, **timeouts) do |remote|
          case config.command
          when "push" then Push.new(config.dir, remote, out: out, err: err).run
          when "pull" then Pull.new(config.dir, remote, out: out, err: err).run
          when "status" then Status.new(config.dir, remote, out: out, err: err).run
          when "sync"
            Sync.new(config.dir, remote, server: config.server.to_s.sub(%r{/+\z}, ""), out: out, err: err).run
          end
        end
        0
      rescue Config::HelpRequested
        out.puts Config::USAGE
        0
      rescue Config::Error => e
        err.puts "syncbox: #{e.message}", Config::USAGE
        EXIT_USAGE
      rescue Failures::Incomplete => e
        err.puts "syncbox: #{e.message}:", *e.failures.map { |failure| "  #{failure}" }
        EXIT_FAILURE
      rescue Error => e
        err.puts "syncbox: #{e.message}"
        EXIT_FAILURE
      rescue Interrupt
        err.puts "syncbox: interrupted"
        EXIT_INTERRUPTED
      end
    end
  end
end
