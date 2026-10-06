# frozen_string_literal: true

module Syncbox
  module Client
    # Частичные сбои при обработке множества файлов (push, pull, sync,
    # status). Сбой одного файла не прерывает команду: он записывается,
    # строка `syncbox: failed <key>: <причина>` уходит в stderr сразу,
    # остальные файлы обрабатываются, а в конце check! поднимает
    # PartialFailure — сводный отчёт по неудачным файлам (код возврата 1).
    # Исключение — ServerUnreachable: без сервера продолжать нечего, команда
    # прерывается сразу.
    class Failures
      Failure = Struct.new(:key, :reason)

      attr_reader :list

      def initialize(command, err:)
        @command = command
        @err = err
        @list = []
      end

      # Выполняет блок для файла key. true — успех. Client::Error (сервер
      # ответил не тем кодом, оборвал соединение или не ответил в срок,
      # непригодный key, расхождение хеша, незаписываемая цель) и ошибки ОС
      # (нечитаемый или пропавший локальный файл) учитываются как сбой этого
      # файла, и возвращается false.
      def attempt(key)
        yield
        true
      rescue ServerUnreachable
        raise
      rescue Error, SystemCallError => e
        add(key, e.message)
        false
      end

      def add(key, reason)
        @list << Failure.new(key, reason)
        @err.puts "syncbox: failed #{self.class.display_key(key)}: #{reason}"
      end

      def any?
        !@list.empty?
      end

      # Бросает PartialFailure, если были сбои; total — сколько файлов
      # обрабатывалось всего.
      def check!(total)
        raise PartialFailure.new(@command, @list, total) if any?
      end

      # key для вывода: как есть, если его можно напечатать; пустой или с
      # управляющими символами (такое может прислать сервер) — в кавычках с
      # экранированием.
      def self.display_key(key)
        key.is_a?(String) && !key.empty? && !key.match?(/[[:cntrl:]]/) ? key : key.inspect
      end
    end
  end
end
