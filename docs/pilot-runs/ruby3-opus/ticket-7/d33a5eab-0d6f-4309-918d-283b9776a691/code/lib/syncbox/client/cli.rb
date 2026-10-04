# frozen_string_literal: true

module Syncbox
  module Client
    # Entry point of the syncbox executable; returns the exit status.
    module CLI
      def self.run(argv, env: ENV, out: $stdout, err: $stderr)
        options = Options.parse(argv, env)
        if options.nil?
          out.puts Options.usage
          return 0
        end

        case options.command
        when "push"
          local_dir = LocalDir.new(options.dir, on_skip: ->(path, why) { err.puts "syncbox: skipping #{path}: #{why}" })
          Remote.open(options.server) { |remote| Push.new(local_dir, remote, out: out).run }
        else
          err.puts "syncbox: '#{options.command}' is not implemented yet (only 'push' is available)"
          return 1
        end
        0
      rescue UsageError => e
        err.puts "syncbox: #{e.message}", Options.usage
        2
      rescue Error => e
        err.puts "syncbox: #{e.message}"
        1
      end
    end
  end
end
