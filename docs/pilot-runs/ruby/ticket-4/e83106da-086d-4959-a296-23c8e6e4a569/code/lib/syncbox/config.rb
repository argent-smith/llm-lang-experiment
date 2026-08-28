module Syncbox
  class ConfigError < StandardError; end

  # Parses server configuration from CLI flags with environment variable
  # fallback, per the CLI contract in SYNCBOX-SPEC.md:
  # --data-dir/SYNCBOX_DATA_DIR (required), --port/SYNCBOX_PORT (default 8080).
  class Config
    DEFAULT_PORT = 8080

    attr_reader :data_dir, :port

    def self.parse(argv, env = ENV)
      data_dir = nil
      port = nil

      args = argv.dup
      until args.empty?
        arg = args.shift
        case arg
        when "--data-dir"
          raise ConfigError, "--data-dir requires a value" if args.empty?

          data_dir = args.shift
        when "--port"
          raise ConfigError, "--port requires a value" if args.empty?

          port = args.shift
        else
          raise ConfigError, "unknown argument: #{arg}"
        end
      end

      data_dir ||= env["SYNCBOX_DATA_DIR"]
      port ||= env["SYNCBOX_PORT"]
      port ||= DEFAULT_PORT.to_s

      raise ConfigError, "--data-dir <path> is required (or SYNCBOX_DATA_DIR)" if data_dir.nil? || data_dir.empty?

      begin
        port_i = Integer(port)
      rescue ArgumentError, TypeError
        raise ConfigError, "--port must be an integer, got: #{port.inspect}"
      end
      raise ConfigError, "--port must be a positive integer, got: #{port.inspect}" unless port_i.positive?

      new(data_dir: data_dir, port: port_i)
    end

    def initialize(data_dir:, port:)
      @data_dir = data_dir
      @port = port
    end
  end
end
