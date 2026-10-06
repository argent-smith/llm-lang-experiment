# frozen_string_literal: true

require "optparse"
require "uri"

module Syncbox
  module Client
    # Client invocation resolved from the command line and environment
    # variables, the flag taking precedence (see "CLI" in SYNCBOX-SPEC.md):
    #
    #   syncbox <push|pull|status|sync> <dir> --server <url>
    #   --server <url>  / SYNCBOX_SERVER  required
    class Config
      COMMANDS = %w[push pull status sync].freeze
      USAGE = "Usage: syncbox <push|pull|status|sync> <dir> --server <url>"

      # Invalid command line or environment; the message is meant for the user.
      class Error < StandardError; end

      # Raised by .parse when -h/--help is given.
      class HelpRequested < StandardError; end

      attr_reader :command, :dir, :server

      def self.parse(argv, env = ENV)
        server = nil
        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.require_exact = true
          opts.on("--server URL") { |v| server = v }
          opts.on("-h", "--help") { raise HelpRequested }
        end
        command, dir, *rest = parser.parse(argv)
        raise Error, "missing command" if command.nil?
        raise Error, "unknown command: #{command}" unless COMMANDS.include?(command)
        raise Error, "missing directory" if dir.nil?
        raise Error, "unexpected argument: #{rest.first}" unless rest.empty?

        new(command: command, dir: dir, server: server || presence(env["SYNCBOX_SERVER"]))
      rescue OptionParser::ParseError => e
        raise Error, e.message
      end

      def self.presence(value)
        value unless value.nil? || value.empty?
      end
      private_class_method :presence

      def initialize(command:, dir:, server:)
        if server.nil? || server.empty?
          raise Error, "server URL is required: pass --server <url> or set SYNCBOX_SERVER"
        end
        raise Error, "directory must not be empty" if dir.empty?

        @command = command
        @dir = File.expand_path(dir)
        @server = parse_server(server)
      end

      private

      def parse_server(value)
        uri = URI.parse(value)
        valid = uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && uri.query.nil? && uri.fragment.nil?
        raise Error, "invalid server URL #{value.inspect}: expected http(s)://<host>[:<port>]" unless valid

        uri
      rescue URI::InvalidURIError
        raise Error, "invalid server URL #{value.inspect}: expected http(s)://<host>[:<port>]"
      end
    end
  end
end
