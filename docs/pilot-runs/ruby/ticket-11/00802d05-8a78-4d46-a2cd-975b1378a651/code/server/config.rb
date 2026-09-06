require "optparse"

module Syncbox
  class Config
    DEFAULT_PORT = 8080

    Error = Class.new(StandardError)

    attr_reader :data_dir, :port

    def self.parse(argv, env = ENV)
      data_dir = env["SYNCBOX_DATA_DIR"]
      port = env["SYNCBOX_PORT"] ? Integer(env["SYNCBOX_PORT"]) : DEFAULT_PORT

      parser = OptionParser.new do |opts|
        opts.on("--data-dir PATH", String, "Directory to store blobs in (required)") do |v|
          data_dir = v
        end
        opts.on("--port N", Integer, "Port to listen on (default #{DEFAULT_PORT})") do |v|
          port = v
        end
      end
      parser.parse!(argv.dup)

      if data_dir.nil? || data_dir.empty?
        raise Error, "--data-dir is required (or set SYNCBOX_DATA_DIR)"
      end

      new(data_dir: data_dir, port: port)
    end

    def initialize(data_dir:, port:)
      @data_dir = data_dir
      @port = port
    end
  end
end
