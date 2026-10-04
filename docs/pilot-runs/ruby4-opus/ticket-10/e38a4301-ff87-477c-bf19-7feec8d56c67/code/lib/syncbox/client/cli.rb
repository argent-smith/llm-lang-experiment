# frozen_string_literal: true

module Syncbox
  module Client
    # Entry point of the syncbox executable.
    module CLI
      EXIT_FAILURE = 1
      EXIT_USAGE = 2
      EXIT_INTERRUPTED = 130

      def self.run(argv, env: ENV, out: $stdout, err: $stderr)
        config = Config.parse(argv, env)
        case config.command
        when "push"
          Remote.open(config.server) { |remote| Push.new(config.dir, remote, out: out, err: err).run }
        when "pull"
          Remote.open(config.server) { |remote| Pull.new(config.dir, remote, out: out, err: err).run }
        when "status"
          Remote.open(config.server) { |remote| Status.new(config.dir, remote, out: out, err: err).run }
        when "sync"
          Remote.open(config.server) do |remote|
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
