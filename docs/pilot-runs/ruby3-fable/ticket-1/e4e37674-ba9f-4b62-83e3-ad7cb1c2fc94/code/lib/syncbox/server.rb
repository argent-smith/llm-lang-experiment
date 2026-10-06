# frozen_string_literal: true

require "puma"
require "puma/configuration"
require "puma/launcher"
require "puma/log_writer"
require "rack"

module Syncbox
  # Запуск HTTP-сервера (Puma) с приложением Syncbox::App.
  class Server
    # Слушаем на всех интерфейсах: сервер работает внутри контейнера,
    # а доступ снаружи ограничивается публикацией порта в compose.yaml.
    BIND_HOST = "0.0.0.0"

    attr_reader :config

    def initialize(config, out: $stdout, err: $stderr)
      @config = config
      @out = out
      @err = err
    end

    # Блокирует текущий поток до остановки сервера (SIGINT/SIGTERM или #stop).
    def run
      @out.puts "syncbox-server #{VERSION}: listening on http://#{BIND_HOST}:#{config.port}, data dir #{config.data_dir}"
      @out.flush
      launcher.run
    end

    def stop
      @launcher&.stop
    end

    private

    def launcher
      @launcher ||= Puma::Launcher.new(puma_configuration, log_writer: Puma::LogWriter.new(@out, @err))
    end

    def puma_configuration
      app = rack_app
      bind = "tcp://#{BIND_HOST}:#{config.port}"
      Puma::Configuration.new do |c|
        c.app app
        c.bind bind
        c.environment "production"
        c.threads 1, 16
        c.tag "syncbox"
        # На SIGTERM Puma корректно завершает работу и не бросает исключение.
        c.raise_exception_on_sigterm false
      end
    end

    def rack_app
      out = @out
      inner = App.new(config)
      Rack::Builder.new do
        use Rack::CommonLogger, out
        run inner
      end.to_app
    end
  end
end
