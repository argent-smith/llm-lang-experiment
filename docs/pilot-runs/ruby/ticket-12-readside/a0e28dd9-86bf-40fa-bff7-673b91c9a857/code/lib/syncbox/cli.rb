require_relative "client"
require_relative "push"

module Syncbox
  class CLIError < StandardError; end

  # Parses argv per the CLI contract in SYNCBOX-SPEC.md
  # (`syncbox <push|pull|status|sync> <dir> --server <url>`) and dispatches
  # to the matching command. `push` is implemented; `pull`/`status`/`sync`
  # are accepted (so run-client's fixed four-command interface never
  # errors on an unrecognized subcommand) but report themselves as not
  # yet implemented rather than doing anything.
  class CLI
    COMMANDS = %w[push pull status sync].freeze
    NOT_YET_IMPLEMENTED = %w[pull status sync].freeze

    Options = Struct.new(:command, :dir, :server, keyword_init: true)

    # Never raises: parse/dispatch/network failures are all reported to
    # stderr and turned into a plain exit code, so bin/syncbox can just do
    # `exit(Syncbox::CLI.run(ARGV))` without its own rescue.
    def self.run(argv, env = ENV, stdout: $stdout, stderr: $stderr)
      options = parse(argv, env)
      dispatch(options, stdout)
      0
    rescue CLIError, Client::ConnectionError, Client::ServerError => e
      stderr.puts "syncbox: #{e.message}"
      1
    end

    def self.parse(argv, env = ENV)
      args = argv.dup

      command = args.shift
      raise CLIError, "missing command (expected one of: #{COMMANDS.join(', ')})" if command.nil?
      unless COMMANDS.include?(command)
        raise CLIError, "unknown command: #{command.inspect} (expected one of: #{COMMANDS.join(', ')})"
      end

      server = nil
      positionals = []

      until args.empty?
        arg = args.shift
        case arg
        when "--server"
          raise CLIError, "--server requires a value" if args.empty?

          server = args.shift
        else
          positionals << arg
        end
      end

      raise CLIError, "missing <dir> argument" if positionals.empty?
      raise CLIError, "unexpected argument: #{positionals[1]}" if positionals.length > 1

      server ||= env["SYNCBOX_SERVER"]
      raise CLIError, "--server <url> is required (or SYNCBOX_SERVER)" if server.nil? || server.empty?

      Options.new(command: command, dir: positionals.first, server: server)
    end

    def self.dispatch(options, stdout)
      if NOT_YET_IMPLEMENTED.include?(options.command)
        raise CLIError, "#{options.command} is not implemented yet"
      end

      run_push(options, stdout)
    end
    private_class_method :dispatch

    def self.run_push(options, stdout)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Push.new(client: client, dir: options.dir).call

      result.uploaded.each { |key| stdout.puts "uploaded #{key}" }
      stdout.puts "push: #{result.uploaded.size} uploaded, #{result.skipped.size} unchanged"
    end
    private_class_method :run_push
  end
end
