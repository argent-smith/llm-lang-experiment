require "optparse"

module Syncbox
  class ClientConfig
    Error = Class.new(StandardError)

    COMMANDS = %w[push pull sync status].freeze

    attr_reader :command, :dir, :server

    def self.parse(argv, env = ENV)
      argv = argv.dup
      command = argv.shift

      unless COMMANDS.include?(command)
        raise Error, "usage: syncbox <#{COMMANDS.join('|')}> <dir> --server <url>"
      end

      dir = argv.shift
      if dir.nil? || dir.empty? || dir.start_with?("-")
        raise Error, "usage: syncbox #{command} <dir> --server <url>"
      end

      server = env["SYNCBOX_SERVER"]
      parser = OptionParser.new do |opts|
        opts.on("--server URL", String, "Syncbox server URL (required)") { |v| server = v }
      end
      parser.parse!(argv)

      if server.nil? || server.empty?
        raise Error, "--server is required (or set SYNCBOX_SERVER)"
      end

      new(command: command, dir: dir, server: server)
    end

    def initialize(command:, dir:, server:)
      @command = command
      @dir = dir
      @server = server
    end
  end
end
