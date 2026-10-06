# frozen_string_literal: true

module Syncbox
  module Client
    # Разбор аргументов, запуск подкоманды, коды возврата:
    #   0 — успех, 1 — сбой выполнения, 2 — ошибка в аргументах (usage).
    module CLI
      EXIT_OK = 0
      EXIT_FAILURE = 1
      EXIT_USAGE = 2

      # Реализованные команды → класс с #run (sync — тикет 10).
      HANDLERS = { "push" => Push, "pull" => Pull, "status" => Status }.freeze

      module_function

      # Возвращает код завершения процесса.
      def run(argv, env: ENV, out: $stdout, err: $stderr)
        options = Options.parse(argv, env: env)
        handler = HANDLERS[options.command]
        unless handler
          raise Error, "#{options.command} is not implemented yet (only #{IMPLEMENTED_COMMANDS.join(', ')} " \
                       "#{IMPLEMENTED_COMMANDS.size == 1 ? 'is' : 'are'} available in this version)"
        end

        handler.new(options, out: out, err: err).run
        EXIT_OK
      rescue HelpRequested => e
        out.puts e.message
        EXIT_OK
      rescue UsageError => e
        err.puts "syncbox: #{e.message}"
        err.puts Options.usage
        EXIT_USAGE
      rescue Error, SystemCallError => e
        err.puts "syncbox: #{e.message}"
        EXIT_FAILURE
      end
    end
  end
end
