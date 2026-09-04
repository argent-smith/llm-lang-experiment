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
    #
    # Two distinct failure paths, both ending in a non-zero exit per
    # SYNCBOX-SPEC.md's "Коды возврата и ошибки": the server being
    # unreachable altogether (connection refused, DNS failure, timeout) or
    # a request that made it there but got a non-success response raises
    # Client::ConnectionError/ServerError out of the initial GET /blobs
    # listing and is caught here; a single file failing partway through an
    # otherwise-successful run is caught per-file inside Push/Pull/Sync and
    # surfaces as Result#failed instead, reported by report_failures below.
    def self.run(argv, env = ENV, stdout: $stdout, stderr: $stderr)
      options = parse(argv, env)
      dispatch(options, stdout, stderr)
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

    def self.dispatch(options, stdout, stderr)
      case options.command
      when "push"
        run_push(options, stdout, stderr)
      when "pull"
        run_pull(options, stdout, stderr)
      when "status"
        run_status(options, stdout, stderr)
      when "sync"
        run_sync(options, stdout, stderr)
      end
    end
    private_class_method :dispatch

    def self.run_push(options, stdout, stderr)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Push.new(client: client, dir: options.dir).call

      result.uploaded.each { |key| stdout.puts "uploaded #{key}" }
      stdout.puts "push: #{result.uploaded.size} uploaded, #{result.skipped.size} unchanged"
      report_failures("push", result.failed, stderr)
    end
    private_class_method :run_push

    def self.run_pull(options, stdout, stderr)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Pull.new(client: client, dir: options.dir).call

      result.downloaded.each { |key| stdout.puts "downloaded #{key}" }
      stdout.puts "pull: #{result.downloaded.size} downloaded, #{result.skipped.size} unchanged"
      report_failures("pull", result.failed, stderr)
    end
    private_class_method :run_pull

    # Strictly read-only against the server and the synced directory's
    # blobs: Status#call only issues GET /blobs and reads local files, so
    # this never writes anything beyond stdout/stderr.
    def self.run_status(options, stdout, stderr)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Status.new(client: client, dir: options.dir).call

      result.to_upload.each { |key| stdout.puts "would upload   #{key}" }
      result.to_download.each { |key| stdout.puts "would download #{key}" }
      stdout.puts "status: #{result.to_upload.size} to upload, " \
                  "#{result.to_download.size} to download, #{result.unchanged.size} unchanged"
      report_failures("status", result.failed, stderr)
    end
    private_class_method :run_status

    def self.run_sync(options, stdout, stderr)
      raise CLIError, "not a directory: #{options.dir}" unless File.directory?(options.dir)

      client = Client.new(server: options.server)
      result = Sync.new(client: client, dir: options.dir).call

      result.uploaded.each { |key| stdout.puts "uploaded #{key}" }
      result.downloaded.each { |key| stdout.puts "downloaded #{key}" }
      stdout.puts "sync: #{result.uploaded.size} uploaded, #{result.downloaded.size} downloaded, " \
                  "#{result.unchanged.size} unchanged"
      report_failures("sync", result.failed, stderr)
    end
    private_class_method :run_sync

    # Prints a summary of per-file failures collected by Push/Pull/Sync/
    # Status (SYNCBOX-SPEC.md's partial-failure rule: one bad file doesn't
    # abort the rest, but the run must still end non-zero and say which
    # file failed and why). Returns the exit code the caller should use: 0
    # if nothing failed, 1 otherwise.
    def self.report_failures(command, failures, stderr)
      return 0 if failures.empty?

      stderr.puts "syncbox: #{command} failed for #{failures.size} file(s):"
      failures.each { |failure| stderr.puts "  #{failure.key}: #{failure.message}" }
      1
    end
    private_class_method :report_failures
  end
end
