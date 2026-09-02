require_relative "client"
require_relative "push"
require_relative "pull"
require_relative "status"
require_relative "sync"

module Syncbox
  class CLIError < StandardError; end

  # Parses argv per the CLI contract in SYNCBOX-SPEC.md
  # (`syncbox <push|pull|status|sync> <dir> --server <url>`) and dispatches
  # to the matching command.
  class CLI
    COMMANDS = %w[push pull status sync].freeze

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
      case options.command
      when "push"
        run_push(options, stdout)
      when "pull"
        run_pull(options, stdout)
      when "status"
        run_status(options, stdout)
      when "sync"
        run_sync(options, stdout)
      else
        raise CLIError, "#{options.command} is not implemented yet"
      end
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

    def self.run_pull(options, stdout)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Pull.new(client: client, dir: options.dir).call

      result.downloaded.each { |key| stdout.puts "downloaded #{key}" }
      stdout.puts "pull: #{result.downloaded.size} downloaded, #{result.skipped.size} unchanged"
    end
    private_class_method :run_pull

    # Strictly read-only: Status#call only issues GET /blobs and reads
    # local files, so this never touches the server or the local
    # filesystem beyond stdout.
    def self.run_status(options, stdout)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Status.new(client: client, dir: options.dir).call

      result.to_upload.each { |key| stdout.puts "would upload   #{key}" }
      result.to_download.each { |key| stdout.puts "would download #{key}" }
      stdout.puts "status: #{result.to_upload.size} to upload, " \
                  "#{result.to_download.size} to download, #{result.unchanged.size} unchanged"
    end
    private_class_method :run_status

    def self.run_sync(options, stdout)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Sync.new(client: client, dir: options.dir).call

      result.uploaded.each { |key| stdout.puts "uploaded #{key}" }
      result.downloaded.each { |key| stdout.puts "downloaded #{key}" }
      stdout.puts "sync: #{result.uploaded.size} uploaded, #{result.downloaded.size} downloaded, " \
                  "#{result.skipped.size} unchanged"
    end
    private_class_method :run_sync
  end
end
