# frozen_string_literal: true

require "optparse"
require "uri"

module Syncbox
  module Client
    # Command line of the client, resolved from argv with the environment as
    # fallback (flags win):
    #
    #   syncbox <push|pull|sync|status> <dir> --server <url>
    #
    #   --server <url>   required               (env SYNCBOX_SERVER)
    #
    # Pure: no filesystem or network access, so it is trivially unit-testable.
    # Whether <dir> exists is checked by the command that uses it.
    class Options
      COMMANDS = %w[push pull sync status].freeze
      SCHEMES = %w[http https].freeze

      class Error < StandardError; end

      # Raised when --help is requested; message carries the usage text.
      class HelpRequested < StandardError; end

      attr_reader :command, :dir, :server

      # +server+ is a URI::HTTP(S) without trailing slash in its path, so that
      # "#{server}/blobs" is always well-formed.
      def initialize(command:, dir:, server:)
        @command = command
        @dir = dir
        @server = server
      end

      def self.parse(argv, env: ENV, program_name: "syncbox")
        options = {}
        parser = build_parser(options, program_name)

        begin
          positional = parser.parse(argv.dup)
        rescue OptionParser::ParseError => e
          raise Error, e.message
        end

        raise HelpRequested, parser.to_s if options[:help]

        command, dir, *extra = positional
        raise Error, "missing command (one of: #{COMMANDS.join(', ')})" if command.nil?
        raise Error, "unknown command #{command.inspect} (expected one of: #{COMMANDS.join(', ')})" unless COMMANDS.include?(command)
        raise Error, "missing <dir> argument" if dir.nil?
        raise Error, "unexpected argument(s): #{extra.join(' ')}" unless extra.empty?

        server = first_present(options[:server], env["SYNCBOX_SERVER"])
        raise Error, "--server is required (or set SYNCBOX_SERVER)" if server.nil?

        new(command: command, dir: dir, server: parse_server(server))
      end

      def self.usage(program_name: "syncbox")
        build_parser({}, program_name).to_s
      end

      def self.build_parser(options, program_name)
        OptionParser.new do |o|
          o.program_name = program_name
          o.banner = "Usage: #{program_name} <#{COMMANDS.join('|')}> <dir> --server <url>"
          o.separator ""
          o.separator "Commands:"
          o.separator "  push     Upload files that are missing on the server or differ from it (by SHA-256)"
          o.separator "  pull     Download files that are missing locally or differ from the server (by SHA-256)"
          o.separator "  sync     Reconcile both ways (not implemented yet)"
          o.separator "  status   Dry run: show what push and pull would do, changing nothing on either side"
          o.separator ""
          o.separator "Options:"
          o.on("--server URL", "Base URL of the Syncbox server (required; env SYNCBOX_SERVER)") do |v|
            options[:server] = v
          end
          o.on("-h", "--help", "Show this help") { options[:help] = true }
        end
      end
      private_class_method :build_parser

      def self.first_present(*values)
        values.find { |v| !v.nil? && !v.to_s.strip.empty? }
      end
      private_class_method :first_present

      # Accepts http(s)://host[:port][/prefix]; the path is kept (minus any
      # trailing slashes) so that a server mounted under a prefix works too.
      def self.parse_server(raw)
        uri = begin
          URI.parse(raw.to_s.strip)
        rescue URI::InvalidURIError => e
          raise Error, "invalid server URL #{raw.inspect}: #{e.message}; expected http://host[:port] or https://host[:port]"
        end

        unless uri.is_a?(URI::HTTP) && SCHEMES.include?(uri.scheme) && uri.host && !uri.host.empty?
          raise Error, "invalid server URL #{raw.inspect}: expected http://host[:port] or https://host[:port]"
        end
        raise Error, "invalid server URL #{raw.inspect}: query and fragment are not allowed" if uri.query || uri.fragment

        uri.path = uri.path.sub(%r{/+\z}, "")
        uri
      end
      private_class_method :parse_server
    end
  end
end
