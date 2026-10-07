# frozen_string_literal: true

require_relative "version"

module Syncbox
  # CLI-клиент Syncbox: синхронизация локального каталога с сервером по HTTP.
  # Точка входа — bin/syncbox (исполняется внутри Docker-контейнера, см.
  # run-client в корне репозитория).
  module Client
    # Подкоманды, принимаемые по интерфейсу. Реализованы push, pull и
    # status; sync — отдельный тикет.
    COMMANDS = %w[push pull sync status].freeze
    IMPLEMENTED_COMMANDS = %w[push pull status].freeze

    # Сбой выполнения команды: сервер недоступен, неожиданный ответ,
    # проблемы с локальными файлами. Код возврата 1.
    class Error < StandardError; end

    # Ошибка использования: некорректные/недостающие аргументы. Код возврата 2.
    class UsageError < StandardError; end

    # Пользователь запросил --help/--version; сообщение — текст для вывода.
    class HelpRequested < StandardError; end
  end
end

require_relative "client/options"
require_relative "client/api"
require_relative "client/local_tree"
require_relative "client/push"
require_relative "client/pull"
require_relative "client/status"
require_relative "client/cli"
