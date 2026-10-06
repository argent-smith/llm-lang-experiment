# frozen_string_literal: true

require "optparse"

module Syncbox
  module Server
    # Server configuration, resolved from CLI flags with environment
    # variables as fallback (flags win):
    #
    #   --data-dir <path>   required          (env SYNCBOX_DATA_DIR)
    #   --port <n>          default 8080      (env SYNCBOX_PORT)
    #
    # Pure: no filesystem access here, so it is trivially unit-testable.
    # Creating/validating the data directory is the Runner's job.
    class Config
      DEFAULT_PORT = 8080
      DEFAULT_HOST = "0.0.0.0"
      PORT_RANGE = (1..65_535)

      class Error < StandardError; end

      # Raised when --help is requested; message carries the usage text.
      class HelpRequested < StandardError; end

      attr_reader :data_dir, :port, :host

      def initialize(data_dir:, port: DEFAULT_PORT, host: DEFAULT_HOST)
        @data_dir = data_dir
        @port = port
        @host = host
      end

      def self.parse(argv, env: ENV, program_name: "syncbox-server")
        options = {}
        parser = build_parser(options, program_name)

        begin
          parser.parse(argv.dup)
        rescue OptionParser::ParseError => e
          raise Error, e.message
        end

        raise HelpRequested, parser.to_s if options[:help]

        data_dir = first_present(options[:data_dir], env["SYNCBOX_DATA_DIR"])
        raise Error, "--data-dir is required (or set SYNCBOX_DATA_DIR)" if data_dir.nil?

        port = parse_port(first_present(options[:port], env["SYNCBOX_PORT"]))

        new(data_dir: File.expand_path(data_dir), port: port)
      end

      def self.usage(program_name: "syncbox-server")
        build_parser({}, program_name).to_s
      end

      def self.build_parser(options, program_name)
        OptionParser.new do |o|
          o.program_name = program_name
          o.banner = "Usage: #{program_name} --data-dir <path> [--port <n>]"
          o.separator ""
          o.separator "Options:"
          o.on("--data-dir PATH", "Storage root directory (required; env SYNCBOX_DATA_DIR)") do |v|
            options[:data_dir] = v
          end
          o.on("--port N", "TCP port to listen on (default #{DEFAULT_PORT}; env SYNCBOX_PORT)") do |v|
            options[:port] = v
          end
          o.on("-h", "--help", "Show this help") { options[:help] = true }
        end
      end
      private_class_method :build_parser

      def self.first_present(*values)
        values.find { |v| !v.nil? && !v.to_s.strip.empty? }
      end
      private_class_method :first_present

      def self.parse_port(raw)
        return DEFAULT_PORT if raw.nil?

        str = raw.to_s.strip
        raise Error, "invalid port #{raw.inspect}: must be an integer" unless str.match?(/\A\d+\z/)

        port = Integer(str, 10)
        unless PORT_RANGE.cover?(port)
          raise Error, "invalid port #{raw.inspect}: must be in #{PORT_RANGE.min}..#{PORT_RANGE.max}"
        end

        port
      end
      private_class_method :parse_port
    end
  end
end
