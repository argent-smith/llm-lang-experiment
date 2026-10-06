# frozen_string_literal: true

require "digest"

module Syncbox
  module Client
    # syncbox push <dir> --server <url>: загрузить на сервер файлы, которых
    # там нет или которые отличаются от серверной версии по SHA-256.
    # Файлы с совпадающим хешем не загружаются; то, что есть на сервере, но
    # нет локально, не трогается.
    #
    # Порядок: сначала полный обход каталога (ошибки обхода — до первого
    # обращения к сети), затем один GET /blobs (без листинга делать нечего:
    # его сбой прерывает команду), затем по каждому файлу в порядке key:
    # хеш → сравнение → при расхождении PUT из того же открытого
    # дескриптора. Сбой одного файла (нечитаем, сервер ответил не 201,
    # оборвал соединение или не ответил в срок) команду не прерывает: он
    # учитывается (Failures), остальные файлы обрабатываются, в конце —
    # сводный отчёт и PartialFailure. Недоступность сервера —
    # ServerUnreachable наружу сразу.
    class Push
      CHUNK_SIZE = 64 * 1024

      Summary = Struct.new(:uploaded, :unchanged, :failed) do
        def total
          uploaded + unchanged + failed
        end
      end

      def initialize(options, out: $stdout, err: $stderr)
        @options = options
        @out = out
        @err = err
      end

      # Возвращает Summary; бросает Client::Error при сбое (PartialFailure,
      # если упала часть файлов).
      def run
        entries = LocalTree.scan(@options.dir) do |rel, reason|
          @err.puts "syncbox: skipping #{rel}: #{reason}"
        end
        summary = Summary.new(0, 0, 0)
        failures = Failures.new("push", err: @err)

        Api.open(@options.server) do |api|
          remote = api.list_blobs.to_h { |meta| [meta["key"], meta["sha256"]] }
          entries.each do |entry|
            uploaded = false
            if failures.attempt(entry.key) { uploaded = push_entry(api, entry, remote[entry.key]) }
              if uploaded
                summary.uploaded += 1
              else
                summary.unchanged += 1
              end
            else
              summary.failed += 1
              @out.puts "failed #{entry.key}"
            end
          end
        end

        @out.puts summary_line(summary)
        failures.check!(summary.total)
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

      def summary_line(summary)
        if summary.failed.zero?
          "push complete: #{summary.uploaded} uploaded, #{summary.unchanged} unchanged, #{summary.total} files total"
        else
          "push incomplete: #{summary.uploaded} uploaded, #{summary.unchanged} unchanged, #{summary.failed} failed, " \
            "#{summary.total} files total"
        end
      end
    end
  end
end
