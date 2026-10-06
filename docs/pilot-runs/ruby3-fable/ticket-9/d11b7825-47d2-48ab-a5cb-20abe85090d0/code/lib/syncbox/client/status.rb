# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox status <dir> --server <url>: dry-run. Сравнивает <dir> со
    # списком блобов на сервере по key и SHA-256 и печатает, что сделали бы
    # push и pull, ничего не меняя: ни одного PUT/DELETE на сервер, ни
    # одного созданного, изменённого или удалённого локального файла.
    # Единственный запрос к серверу — GET /blobs (в листинге уже есть
    # sha256, тела блобов для сравнения не нужны).
    #
    # Порядок: полный обход каталога (ошибки локальной стороны — до первого
    # обращения к сети), один GET /blobs, затем по каждому key из объединения
    # обеих сторон в порядке key — вердикт. Первая же ошибка (сетевая,
    # неожиданный ответ, нечитаемый файл) прерывает команду — Client::Error
    # наружу; продолжение после частичного сбоя — тикет 11.
    class Status
      # Вердикт по одному key. Сторона, которой нет, — nil.
      Item = Struct.new(:key, :verdict, :local_size, :remote_size)

      Summary = Struct.new(:local_only, :remote_only, :differing, :unchanged) do
        def total
          local_only + remote_only + differing + unchanged
        end

        # Сколько файлов загрузил бы push / скачал бы pull.
        def to_upload
          local_only + differing
        end

        def to_download
          remote_only + differing
        end

        def in_sync?
          to_upload.zero? && to_download.zero?
        end
      end

      def initialize(options, out: $stdout, err: $stderr)
        @options = options
        @out = out
        @err = err
      end

      # Возвращает Summary; бросает Client::Error при сбое. Код возврата
      # команды — 0 и при расхождениях: status их показывает, не исправляет.
      def run
        entries = LocalTree.scan(@options.dir) do |rel, reason|
          @err.puts "syncbox: skipping #{rel}: #{reason}"
        end
        remote = Api.open(@options.server) { |api| index_listing(api.list_blobs) }
        local = entries.to_h { |entry| [entry.key, LocalTree.digest(entry.path)] }

        summary = Summary.new(0, 0, 0, 0)
        (local.keys | remote.keys).sort.each do |key|
          item = compare(key, local[key], remote[key])
          summary[item.verdict] += 1
          @out.puts describe(item)
        end
        @out.puts summary_line(summary)
        summary
      end

      private

      # key → [sha256, size] из листинга сервера. Серверу не доверяем:
      # запись без строковых key/sha256 — ошибка, а не падение на nil.
      def index_listing(list)
        list.to_h do |meta|
          key = meta["key"] if meta.is_a?(Hash)
          sha256 = meta["sha256"] if meta.is_a?(Hash)
          raise Error, "GET /blobs: malformed entry in server listing: #{meta.inspect}" unless key.is_a?(String) && sha256.is_a?(String)

          [key, [sha256, meta["size"]]]
        end
      end

      def compare(key, local, remote)
        local_sha256, local_size = local
        remote_sha256, remote_size = remote
        verdict =
          if remote.nil? then :local_only
          elsif local.nil? then :remote_only
          elsif local_sha256 == remote_sha256 then :unchanged
          else :differing
          end
        Item.new(key, verdict, local_size, remote_size)
      end

      # По строке на файл в порядке key. Первое слово — что сделал бы sync-
      # инструмент с этим файлом; direction различима по нему же.
      def describe(item)
        case item.verdict
        when :local_only
          "upload    #{item.key} (#{bytes(item.local_size)}; only local, not on server)"
        when :remote_only
          "download  #{item.key} (#{bytes(item.remote_size)}; only on server, not local)"
        when :differing
          "differs   #{item.key} (local #{bytes(item.local_size)}, server #{bytes(item.remote_size)}; " \
            "push would upload, pull would download)"
        else
          "unchanged #{item.key}"
        end
      end

      def summary_line(summary)
        if summary.in_sync?
          "status: in sync, #{summary.unchanged} unchanged, nothing to upload or download (dry run, nothing changed)"
        else
          "status: #{summary.to_upload} to upload (#{summary.local_only} only local), " \
            "#{summary.to_download} to download (#{summary.remote_only} only on server), " \
            "#{summary.differing} differing on both sides, #{summary.unchanged} unchanged, " \
            "#{summary.total} files total (dry run, nothing changed)"
        end
      end

      def bytes(size)
        size.is_a?(Integer) ? "#{size} bytes" : "size unknown"
      end
    end
  end
end
