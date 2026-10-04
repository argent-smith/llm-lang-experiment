# frozen_string_literal: true

module Syncbox
  module Client
    # Entry point of the syncbox executable; returns the exit status.
    module CLI
      IMPLEMENTED = %w[push pull status].freeze

      def self.run(argv, env: ENV, out: $stdout, err: $stderr)
        options = Options.parse(argv, env)
        if options.nil?
          out.puts Options.usage
          return 0
        end

        unless IMPLEMENTED.include?(options.command)
          err.puts "syncbox: '#{options.command}' is not implemented yet (available: #{IMPLEMENTED.join(', ')})"
          return 1
        end

        local_dir = LocalDir.new(options.dir, on_skip: ->(path, why) { err.puts "syncbox: skipping #{path}: #{why}" })
        Remote.open(options.server) do |remote|
          case options.command
          when "push" then Push.new(local_dir, remote, out: out).run
          when "pull" then Pull.new(local_dir, remote, out: out).run
          when "status" then Status.new(local_dir, remote, out: out, err: err).run
          end
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
