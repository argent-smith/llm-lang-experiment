# frozen_string_literal: true

require "fileutils"
require "optparse"

module Syncbox
  module Server
    # Server settings resolved from command-line flags and environment
    # variables, flags taking precedence (see "CLI" in SYNCBOX-SPEC.md):
    #
    #   --data-dir <path>  / SYNCBOX_DATA_DIR  required
    #   --port <n>         / SYNCBOX_PORT      default 8080
    class Config
      DEFAULT_PORT = 8080
      PORT_RANGE = 1..65_535
      USAGE = "Usage: syncbox-server --data-dir <path> [--port <n>]"

      # Invalid command line or environment; the message is meant for the user.
      class Error < StandardError; end

      # Raised by .parse when -h/--help is given.
      class HelpRequested < StandardError; end

      attr_reader :data_dir, :port

      def self.parse(argv, env = ENV)
        flags = {}
        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.require_exact = true
          opts.on("--data-dir PATH") { |v| flags[:data_dir] = v }
          opts.on("--port N") { |v| flags[:port] = v }
          opts.on("-h", "--help") { raise HelpRequested }
        end
        rest = parser.parse(argv)
        raise Error, "unexpected argument: #{rest.first}" unless rest.empty?

        new(
          data_dir: flags[:data_dir] || presence(env["SYNCBOX_DATA_DIR"]),
          port: flags[:port] || presence(env["SYNCBOX_PORT"]) || DEFAULT_PORT.to_s,
        )
      rescue OptionParser::ParseError => e
        raise Error, e.message
      end

      def self.presence(value)
        value unless value.nil? || value.empty?
      end
      private_class_method :presence

      def initialize(data_dir:, port:)
        if data_dir.nil? || data_dir.empty?
          raise Error, "data directory is required: pass --data-dir <path> or set SYNCBOX_DATA_DIR"
        end

        @data_dir = File.expand_path(data_dir)
        @port = parse_port(port)
      end

      # Creates the data directory if needed and checks that it is usable.
      def prepare_data_dir!
        FileUtils.mkdir_p(data_dir)
        raise Error, "data directory is not writable: #{data_dir}" unless File.writable?(data_dir)
      rescue Errno::EEXIST, Errno::ENOTDIR
        raise Error, "data directory path is not a directory: #{data_dir}"
      rescue SystemCallError => e
        raise Error, "cannot create data directory #{data_dir}: #{e.message}"
      end

      private

      def parse_port(value)
        port = value.to_s.match?(/\A\d+\z/) && Integer(value, 10)
        unless port && PORT_RANGE.cover?(port)
          raise Error, "invalid port #{value.to_s.inspect}: expected an integer in #{PORT_RANGE}"
        end

        port
      end
    end
  end
end
