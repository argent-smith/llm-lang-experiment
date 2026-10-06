# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox pull <dir> --server <url>: скачать с сервера блобы, которых нет
    # в <dir> или которые отличаются от локального файла по SHA-256, и
    # записать их в <dir> по относительному пути, равному key. Файлы с
    # совпадающим хешем не скачиваются; локальные файлы, которых нет на
    # сервере, не трогаются — зеркало push.
    #
    # Порядок: проверка каталога, один GET /blobs (без листинга делать
    # нечего: его сбой или битая запись в нём прерывают команду), затем по
    # каждому блобу в порядке key: проверка key и локального пути
    # (LocalTarget) → хеш локального файла → при расхождении
    # GET /blobs/{key} потоково во временный файл рядом с целью → сверка хеша
    # с листингом → rename на место (Transfer.download). Блобы под
    # зарезервированным именем STATE_DIR пропускаются с предупреждением.
    # Сбой одного блоба (сервер ответил не 200, оборвал соединение или не
    # ответил в срок, непригодный key, расхождение хеша, нечитаемый или
    # незаписываемый локальный файл) команду не прерывает: он учитывается
    # (Failures), остальные блобы обрабатываются, в конце — сводный отчёт и
    # PartialFailure. Недоступность сервера — ServerUnreachable наружу сразу.
    class Pull
      Summary = Struct.new(:downloaded, :unchanged, :failed) do
        def total
          downloaded + unchanged + failed
        end
      end

      def initialize(options, out: $stdout, err: $stderr)
        @options = options
        @out = out
        @err = err
      end

      # Возвращает Summary; бросает Client::Error при сбое (PartialFailure,
      # если упала часть блобов).
      def run
        @root = LocalTree.check_dir(@options.dir)
        summary = Summary.new(0, 0, 0)
        failures = Failures.new("pull", err: @err)

        Api.open(@options.server) do |api|
          listing(api.list_blobs).each do |meta|
            key = meta["key"]
            if Client.reserved_key?(key)
              @err.puts "syncbox: skipping #{key}: #{Client.reserved_key_reason}"
              next
            end

            downloaded = false
            if failures.attempt(key) { downloaded = pull_blob(api, meta) }
              if downloaded
                summary.downloaded += 1
              else
                summary.unchanged += 1
              end
            else
              summary.failed += 1
              @out.puts "failed #{Failures.display_key(key)}"
            end
          end
        end

        @out.puts summary_line(summary)
        failures.check!(summary.total)
        summary
      end

      private

      # Записи листинга в порядке key. Серверу не доверяем: запись без
      # строковых key/sha256 — ошибка (листинг целиком непригоден).
      def listing(list)
        list.each do |meta|
          key = meta["key"] if meta.is_a?(Hash)
          sha256 = meta["sha256"] if meta.is_a?(Hash)
          raise Error, "GET /blobs: malformed entry in server listing: #{meta.inspect}" unless key.is_a?(String) && sha256.is_a?(String)
        end
        list.sort_by { |meta| meta["key"] }
      end

      # true, если блоб скачан; false, если локальный файл уже идентичен.
      def pull_blob(api, meta)
        key = meta["key"]
        remote_sha256 = meta["sha256"]
        path = LocalTarget.path_for(@root, @options.dir, key, command: "pull")
        stat = LocalTarget.file_stat(key, path)
        if stat && LocalTree.digest(path).first == remote_sha256
          @out.puts "unchanged #{key}"
          return false
        end

        size = Transfer.download(api, key, remote_sha256, path, stat)
        @out.puts "downloaded #{key} (#{size} bytes)"
        true
      end

      def summary_line(summary)
        if summary.failed.zero?
          "pull complete: #{summary.downloaded} downloaded, #{summary.unchanged} unchanged, #{summary.total} files total"
        else
          "pull incomplete: #{summary.downloaded} downloaded, #{summary.unchanged} unchanged, #{summary.failed} failed, " \
            "#{summary.total} files total"
        end
      end
    end
  end
end
