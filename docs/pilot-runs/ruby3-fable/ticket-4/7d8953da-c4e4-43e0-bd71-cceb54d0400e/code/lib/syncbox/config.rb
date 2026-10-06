# frozen_string_literal: true

require "optparse"

module Syncbox
  # Конфигурация сервера. Источники в порядке приоритета:
  #   1. флаги командной строки: --data-dir <path>, --port <n>
  #   2. переменные окружения:   SYNCBOX_DATA_DIR, SYNCBOX_PORT
  #   3. значения по умолчанию:  --port 8080; --data-dir обязателен.
  class Config
    DEFAULT_PORT = 8080
    PORT_RANGE = (1..65_535)

    # Ошибка использования: некорректные/недостающие параметры.
    class UsageError < StandardError; end

    # Пользователь запросил --help; сообщение — текст подсказки.
    class HelpRequested < StandardError; end

    attr_reader :data_dir, :port

    def initialize(data_dir:, port: DEFAULT_PORT)
      @data_dir = File.expand_path(data_dir)
      @port = Integer(port)
    end

    def self.parse(argv, env: ENV)
      options = {}
      parser = build_parser(options)
      parser.parse(argv.dup)

      data_dir = options.fetch(:data_dir) { presence(env["SYNCBOX_DATA_DIR"]) }
      raise UsageError, "--data-dir is required (or set SYNCBOX_DATA_DIR)" if data_dir.nil?

      port = options.fetch(:port) { parse_port(env["SYNCBOX_PORT"], source: "SYNCBOX_PORT") }

      new(data_dir: data_dir, port: port)
    rescue OptionParser::ParseError => e
      raise UsageError, e.message
    end

    def self.usage
      build_parser({}).to_s
    end

    def self.build_parser(options)
      OptionParser.new do |op|
        op.banner = "Usage: syncbox-server --data-dir <path> [--port <n>]"
        op.separator ""
        op.separator "Options:"
        op.on("--data-dir PATH", "Directory where blobs are stored (required; env: SYNCBOX_DATA_DIR)") do |v|
          options[:data_dir] = v
        end
        op.on("--port N", "TCP port to listen on (default: #{DEFAULT_PORT}; env: SYNCBOX_PORT)") do |v|
          options[:port] = parse_port(v, source: "--port", blank_is_default: false)
        end
        op.on("-h", "--help", "Show this help") do
          raise HelpRequested, op.to_s
        end
        op.on("--version", "Show version") do
          raise HelpRequested, "syncbox-server #{VERSION}"
        end
      end
    end
    private_class_method :build_parser

    # Пустое значение переменной окружения равносильно её отсутствию
    # (blank_is_default: true); пустое значение флага — ошибка.
    def self.parse_port(value, source:, blank_is_default: true)
      value = presence(value)
      return DEFAULT_PORT if value.nil? && blank_is_default

      port = Integer(value.to_s, 10, exception: false)
      unless port && PORT_RANGE.cover?(port)
        raise UsageError, "invalid #{source} value #{value.inspect}: expected an integer in #{PORT_RANGE}"
      end

      port
    end
    private_class_method :parse_port

    def self.presence(value)
      value.nil? || value.strip.empty? ? nil : value
    end
    private_class_method :presence
  end
end
