# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox pull <dir> --server <url>: скачать с сервера блобы, которых нет
    # в <dir> или которые отличаются от локального файла по SHA-256, и
    # записать их в <dir> по относительному пути, равному key. Файлы с
    # совпадающим хешем не скачиваются; локальные файлы, которых нет на
    # сервере, не трогаются — зеркало push.
    #
    # Порядок: проверка каталога, один GET /blobs, затем по каждому блобу в
    # порядке key: проверка key и локального пути (LocalTarget) → хеш
    # локального файла → при расхождении GET /blobs/{key} потоково во
    # временный файл рядом с целью → сверка хеша с листингом → rename на
    # место (Transfer.download). Блобы под зарезервированным именем
    # STATE_DIR пропускаются с предупреждением. Первая же ошибка (сетевая,
    # неожиданный ответ, непригодный key, нечитаемый или незаписываемый
    # файл) прерывает команду — Client::Error наружу; продолжение после
    # частичного сбоя — тикет 11.
    class Pull
      Summary = Struct.new(:downloaded, :unchanged) do
        def total
          downloaded + unchanged
        end
      end

      def initialize(options, out: $stdout, err: $stderr)
        @options = options
        @out = out
        @err = err
      end

      # Возвращает Summary; бросает Client::Error при сбое.
      def run
        @root = LocalTree.check_dir(@options.dir)
        summary = Summary.new(0, 0)

        Api.open(@options.server) do |api|
          blobs = api.list_blobs.sort_by { |meta| meta["key"].to_s }
          blobs.each do |meta|
            if meta["key"].is_a?(String) && Client.reserved_key?(meta["key"])
              @err.puts "syncbox: skipping #{meta['key']}: #{Client.reserved_key_reason}"
              next
            end

            if pull_blob(api, meta)
              summary.downloaded += 1
            else
              summary.unchanged += 1
            end
          end
        end

        @out.puts "pull complete: #{summary.downloaded} downloaded, #{summary.unchanged} unchanged, " \
                  "#{summary.total} files total"
        summary
      end

      private

      # true, если блоб скачан; false, если локальный файл уже идентичен.
      def pull_blob(api, meta)
        key = meta["key"]
        remote_sha256 = meta["sha256"]
        unless key.is_a?(String) && remote_sha256.is_a?(String)
          raise Error, "GET /blobs: malformed entry in server listing: #{meta.inspect}"
        end

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
    end
  end
end
