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

    # Сигналы, по которым сервер корректно останавливается.
    STOP_SIGNALS = %w[TERM INT].freeze

    attr_reader :config

    def initialize(config, out: $stdout, err: $stderr)
      @config = config
      @out = out
      @err = err
    end

    # Блокирует текущий поток до остановки сервера (SIGINT/SIGTERM или #stop).
    #
    # Puma работает в отдельном потоке, а обработчики SIGTERM/SIGINT лишь
    # кладут сигнал в очередь — остановку выполняет главный поток из обычного
    # контекста. Штатный обработчик Puma делает блокирующую остановку (join
    # потока сервера) прямо внутри trap-обработчика, и на Ruby 3.3.12 с Puma
    # 8.0.2 это изредка (около 2% случаев, если SIGTERM пришёл сразу после
    # обработки запросов) зависает навсегда в IO#close служебного pipe
    # сервера; с остановкой из главного потока зависание не воспроизводится.
    def run
      @out.puts "syncbox-server #{VERSION}: listening on http://#{BIND_HOST}:#{config.port}, data dir #{config.data_dir}"
      @out.flush

      signals = Thread::Queue.new
      # Puma ставит свои обработчики в начале Launcher#run; свои ставим после
      # того, как сервер поднялся, — иначе Puma их перезапишет.
      launcher.events.after_booted do
        STOP_SIGNALS.each { |signal| Signal.trap(signal) { signals << signal } }
      end

      thread = Thread.new do
        launcher.run
      ensure
        signals << :exited
      end
      # Исключение из Puma (например, занятый порт) наружу отдаёт join ниже.
      thread.report_on_exception = false

      launcher.stop unless signals.pop == :exited
      thread.join
      nil
    end

    # Корректная остановка из другого потока (Puma сам дожидается запросов).
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
