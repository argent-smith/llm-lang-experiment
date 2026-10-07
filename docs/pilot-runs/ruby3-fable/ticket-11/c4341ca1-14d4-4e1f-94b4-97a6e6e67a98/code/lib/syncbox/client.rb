# frozen_string_literal: true

require_relative "version"

module Syncbox
  # CLI-клиент Syncbox: синхронизация локального каталога с сервером по HTTP.
  # Точка входа — bin/syncbox (исполняется внутри Docker-контейнера, см.
  # run-client в корне репозитория).
  module Client
    # Подкоманды клиента.
    COMMANDS = %w[push pull sync status].freeze

    # Служебный каталог клиента в корне <dir>: здесь sync хранит последнее
    # известное общее состояние (см. SyncState). Имя зарезервировано на
    # стороне клиента: его содержимое не считается файлами <dir> (push,
    # status и sync его не видят), а блобы сервера с таким первым сегментом
    # key пропускаются при pull и sync, чтобы сервер не мог подменить
    # состояние клиента.
    STATE_DIR = ".syncbox"

    # Сбой выполнения команды: сервер недоступен, неожиданный ответ,
    # проблемы с локальными файлами. Код возврата 1.
    class Error < StandardError; end

    # До сервера не достучаться: имя не резолвится, соединение отклонено,
    # нет маршрута, таймаут соединения. Команда прерывается сразу — без
    # сервера продолжать нечего (в отличие от сбоя одного запроса, который
    # считается сбоем одного файла, см. Failures).
    class ServerUnreachable < Error; end

    # Частичный сбой: часть файлов не перенеслась, остальные обработаны до
    # конца. Сообщение — сводный отчёт по неудачным файлам (какой файл, что
    # случилось). Код возврата 1.
    class PartialFailure < Error
      attr_reader :command, :failures, :total

      # failures — массив Failures::Failure, total — сколько файлов обрабатывалось.
      def initialize(command, failures, total)
        @command = command
        @failures = failures
        @total = total
        lines = ["#{command} failed for #{failures.size} of #{total} files:"]
        failures.each { |failure| lines << "  #{Failures.display_key(failure.key)}: #{failure.reason}" }
        super(lines.join("\n"))
      end
    end

    # Ошибка использования: некорректные/недостающие аргументы. Код возврата 2.
    class UsageError < StandardError; end

    # Пользователь запросил --help/--version; сообщение — текст для вывода.
    class HelpRequested < StandardError; end

    # true, если key (относительный POSIX-путь) лежит в STATE_DIR.
    def self.reserved_key?(key)
      key == STATE_DIR || key.start_with?("#{STATE_DIR}/")
    end

    # Почему key пропускается (для сообщений «skipping <key>: ...»).
    def self.reserved_key_reason
      "#{STATE_DIR}/ is reserved for the client's sync state"
    end
  end
end

require_relative "client/options"
require_relative "client/api"
require_relative "client/local_tree"
require_relative "client/local_target"
require_relative "client/transfer"
require_relative "client/failures"
require_relative "client/sync_state"
require_relative "client/push"
require_relative "client/pull"
require_relative "client/status"
require_relative "client/sync"
require_relative "client/cli"
