# frozen_string_literal: true

require "fileutils"
require "optparse"

module Syncbox
  module Server
    class ConfigError < StandardError; end

    DEFAULT_PORT = 8080

    # Server settings resolved from command-line flags, falling back to
    # SYNCBOX_* environment variables. Flags take precedence.
    Config = Data.define(:data_dir, :port) do
      def self.parse(argv, env = ENV)
        opts = {}
        parser = OptionParser.new do |o|
          o.banner = "Usage: syncbox-server --data-dir <path> [--port <n>]"
          o.on("--data-dir PATH", String, "Storage directory (env: SYNCBOX_DATA_DIR, required)") { |v| opts[:data_dir] = v }
          o.on("--port N", String, "TCP port to listen on (env: SYNCBOX_PORT, default: #{DEFAULT_PORT})") { |v| opts[:port] = v }
        end
        rest = parser.parse(argv)
        raise ConfigError, "unexpected argument: #{rest.first}" unless rest.empty?

        data_dir = opts[:data_dir] || env["SYNCBOX_DATA_DIR"]
        raise ConfigError, "--data-dir (or SYNCBOX_DATA_DIR) is required" if data_dir.nil? || data_dir.empty?

        port_source = opts.key?(:port) ? "--port" : "SYNCBOX_PORT"
        raw_port = opts[:port] || env["SYNCBOX_PORT"]
        raw_port = nil if raw_port&.empty?

        new(data_dir: File.expand_path(data_dir), port: parse_port(raw_port, port_source))
      rescue OptionParser::ParseError => e
        raise ConfigError, e.message
      end

      def self.parse_port(raw, source)
        return DEFAULT_PORT if raw.nil?

        port = Integer(raw, 10, exception: false)
        unless port && port.between?(1, 65_535)
          raise ConfigError, "#{source} must be an integer between 1 and 65535, got #{raw.inspect}"
        end

        port
      end
      private_class_method :parse_port

      # Creates the data directory if needed and checks that it is usable.
      def prepare_data_dir!
        FileUtils.mkdir_p(data_dir)
        raise ConfigError, "data dir #{data_dir} is not writable" unless File.writable?(data_dir)
      rescue SystemCallError => e
        raise ConfigError, "cannot use data dir #{data_dir}: #{e.message}"
      end
    end
  end
end
