# frozen_string_literal: true

require "digest"

module Syncbox
  module Client
    # syncbox push <dir> --server <url>: загрузить на сервер файлы, которых
    # там нет или которые отличаются от серверной версии по SHA-256.
    # Файлы с совпадающим хешем не загружаются; то, что есть на сервере, но
    # нет локально, не трогается.
    #
    # Порядок: сначала полный обход каталога (ошибки локальной стороны —
    # до первого обращения к сети), затем один GET /blobs, затем по каждому
    # файлу в порядке key: хеш → сравнение → при расхождении PUT из того же
    # открытого дескриптора. Первая же ошибка (сетевая, неожиданный ответ,
    # нечитаемый файл) прерывает команду — Client::Error наружу.
    class Push
      CHUNK_SIZE = 64 * 1024

      Summary = Struct.new(:uploaded, :unchanged) do
        def total
          uploaded + unchanged
        end
      end

      def initialize(options, out: $stdout, err: $stderr)
        @options = options
        @out = out
        @err = err
      end

      # Возвращает Summary; бросает Client::Error при сбое.
      def run
        entries = LocalTree.scan(@options.dir) do |rel, reason|
          @err.puts "syncbox: skipping #{rel}: #{reason}"
        end
        summary = Summary.new(0, 0)

        Api.open(@options.server) do |api|
          remote = api.list_blobs.to_h { |meta| [meta["key"], meta["sha256"]] }
          entries.each do |entry|
            if push_entry(api, entry, remote[entry.key])
              summary.uploaded += 1
            else
              summary.unchanged += 1
            end
          end
        end

        @out.puts "push complete: #{summary.uploaded} uploaded, #{summary.unchanged} unchanged, #{summary.total} files total"
        summary
      end

      private

      # true, если файл был загружен; false, если сервер уже хранит то же.
      def push_entry(api, entry, remote_sha256)
        File.open(entry.path, "rb") do |file|
          sha256, size = digest(file)
          if sha256 == remote_sha256
            @out.puts "unchanged #{entry.key}"
            return false
          end

          file.rewind
          Transfer.upload(api, entry.key, file, size, sha256)
          @out.puts "uploaded #{entry.key} (#{size} bytes)"
          true
        end
      end

      def digest(file)
        digest = Digest::SHA256.new
        size = 0
        while (chunk = file.read(CHUNK_SIZE))
          digest.update(chunk)
          size += chunk.bytesize
        end
        [digest.hexdigest, size]
      end
    end
  end
end
