# frozen_string_literal: true

require "optparse"
require "uri"

module Syncbox
  module Client
    COMMANDS = %w[push pull sync status].freeze

    # A parsed command line: syncbox <command> <dir> --server <url>.
    # --server falls back to SYNCBOX_SERVER; the flag takes precedence.
    Options = Data.define(:command, :dir, :server) do
      def self.usage
        "Usage: syncbox <#{COMMANDS.join('|')}> <dir> --server <url>"
      end

      # Returns Options, or nil if help was requested.
      def self.parse(argv, env = ENV)
        server = nil
        help = false
        parser = OptionParser.new do |o|
          o.banner = usage
          o.on("--server URL", String, "Syncbox server base URL (env: SYNCBOX_SERVER, required)") { |v| server = v }
          o.on("-h", "--help") { help = true }
        end
        command, dir, *rest = parser.parse(argv)
        return nil if help

        raise UsageError, "missing command" if command.nil?
        raise UsageError, "unknown command: #{command}" unless COMMANDS.include?(command)
        raise UsageError, "missing <dir>" if dir.nil? || dir.empty?
        raise UsageError, "unexpected argument: #{rest.first}" unless rest.empty?

        server = env["SYNCBOX_SERVER"] if server.nil?
        raise UsageError, "--server (or SYNCBOX_SERVER) is required" if server.nil? || server.empty?

        new(command: command, dir: dir, server: parse_server(server))
      rescue OptionParser::ParseError => e
        raise UsageError, e.message
      end

      def self.parse_server(raw)
        uri = URI.parse(raw)
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.query.nil? && uri.fragment.nil?
          raise UsageError, "--server must be an http:// or https:// URL, got #{raw.inspect}"
        end

        uri
      rescue URI::InvalidURIError
        raise UsageError, "--server must be an http:// or https:// URL, got #{raw.inspect}"
      end
      private_class_method :parse_server
    end
  end
end
