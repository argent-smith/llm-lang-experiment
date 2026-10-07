# frozen_string_literal: true

require "optparse"
require "uri"

module Syncbox
  module Client
    # Аргументы клиента: syncbox <push|pull|sync|status> <dir> --server <url>.
    #
    # --server обязателен; вместо флага можно задать переменную окружения
    # SYNCBOX_SERVER (флаг имеет приоритет). Флаги и позиционные аргументы
    # могут идти в любом порядке.
    class Options
      attr_reader :command, :dir, :server

      # server — URI::HTTP без хвостовых `/` в пути.
      def initialize(command:, dir:, server:)
        @command = command
        @dir = dir
        @server = server
      end

      def self.parse(argv, env: ENV)
        options = {}
        rest = argv.dup
        build_parser(options).parse!(rest)

        command, dir, *extra = rest
        raise UsageError, "command is required: one of #{COMMANDS.join(', ')}" if command.nil?
        raise UsageError, "unknown command #{command.inspect}: expected one of #{COMMANDS.join(', ')}" unless COMMANDS.include?(command)
        raise UsageError, "#{command} requires <dir>" if dir.nil?
        raise UsageError, "unexpected arguments: #{extra.join(' ')}" unless extra.empty?

        server = options.fetch(:server) do
          value = presence(env["SYNCBOX_SERVER"])
          raise UsageError, "--server is required (or set SYNCBOX_SERVER)" if value.nil?

          parse_server(value, source: "SYNCBOX_SERVER")
        end

        new(command: command, dir: dir, server: server)
      rescue OptionParser::ParseError => e
        raise UsageError, e.message
      end

      def self.usage
        build_parser({}).to_s
      end

      def self.build_parser(options)
        OptionParser.new do |op|
          op.banner = "Usage: syncbox <#{COMMANDS.join('|')}> <dir> --server <url>"
          op.separator ""
          op.separator "Commands:"
          op.separator "  push     upload files that are missing on the server or differ from it by SHA-256"
          op.separator "  pull     download files that are missing locally or differ from the server by SHA-256"
          op.separator "  sync     two-way: upload local-only/changed files, download server-only/changed ones;"
          op.separator "           if both sides changed since the last sync, the newer mtime wins (tie: local)"
          op.separator "  status   dry run: show what push and pull would do, changing nothing"
          op.separator ""
          op.separator "Options:"
          op.on("--server URL", "Server base URL, e.g. http://127.0.0.1:8080 (required; env: SYNCBOX_SERVER)") do |v|
            options[:server] = parse_server(v, source: "--server")
          end
          op.on("-h", "--help", "Show this help") do
            raise HelpRequested, op.to_s
          end
          op.on("--version", "Show version") do
            raise HelpRequested, "syncbox #{VERSION}"
          end
        end
      end
      private_class_method :build_parser

      # Разбирает и проверяет адрес сервера: только http/https с хостом.
      # Хвостовые `/` в пути убираются, чтобы пути API приклеивались ровно.
      def self.parse_server(value, source:)
        value = presence(value)
        raise UsageError, "#{source} value must not be empty" if value.nil?

        uri = URI.parse(value.strip)
        unless uri.is_a?(URI::HTTP) && presence(uri.host)
          raise UsageError, "invalid #{source} value #{value.inspect}: expected an http(s) URL like http://127.0.0.1:8080"
        end
        raise UsageError, "invalid #{source} value #{value.inspect}: query and fragment are not allowed" if uri.query || uri.fragment

        uri.path = uri.path.sub(%r{/+\z}, "")
        uri
      rescue URI::InvalidURIError
        raise UsageError, "invalid #{source} value #{value.inspect}: expected an http(s) URL like http://127.0.0.1:8080"
      end
      private_class_method :parse_server

      def self.presence(value)
        value.nil? || value.strip.empty? ? nil : value
      end
      private_class_method :presence
    end
  end
end
