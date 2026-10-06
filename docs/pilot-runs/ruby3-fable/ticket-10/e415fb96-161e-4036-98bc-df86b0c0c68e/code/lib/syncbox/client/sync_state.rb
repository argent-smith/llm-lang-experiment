# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Syncbox
  module Client
    # Последнее известное общее состояние <dir> и сервера для sync: по
    # каждому key — SHA-256 содержимого, которое после прошлого sync лежало
    # и локально, и на сервере. Относительно него sync решает, какая сторона
    # изменилась, и только когда изменились обе, применяет правило mtime.
    #
    # Хранится в <dir>/.syncbox/state.json (STATE_DIR зарезервирован, см.
    # Client). Для первого запуска файла нет — общее состояние пустое.
    # Запись атомарна (временный файл в том же каталоге и rename), чтобы
    # прерванный sync не оставил полузаписанный манифест. Без файла sync
    # по-прежнему корректен — просто не отличит «изменилось с одной стороны»
    # от «изменилось с обеих», поэтому разошедшиеся файлы будут разрешаться
    # по правилу mtime.
    class SyncState
      FILE_NAME = "state.json"
      FORMAT_VERSION = 1

      attr_reader :path

      # Читает состояние из <root>/.syncbox/state.json (нет файла — пустое).
      def self.load(root)
        state = new(root)
        state.read
        state
      end

      def initialize(root)
        @dir = File.join(root, STATE_DIR)
        @path = File.join(@dir, FILE_NAME)
        @files = {}
      end

      def [](key)
        @files[key]
      end

      def keys
        @files.keys
      end

      def to_h
        @files.dup
      end

      # Заменяет состояние целиком: key → sha256. Возвращает true, если оно
      # отличается от прочитанного/сохранённого ранее.
      def replace(files)
        files = files.sort.to_h
        changed = files != @files
        @files = files
        changed
      end

      # Читает манифест; отсутствующий файл — пустое состояние. Повреждённый
      # манифест — ошибка с указанием пути: молча начать с нуля значило бы
      # скрыть проблему, а дальше sync уже сам решит конфликты по mtime.
      def read
        raw = File.binread(@path)
        @files = parse(raw)
      rescue Errno::ENOENT
        @files = {}
      rescue Errno::EISDIR, Errno::ENOTDIR, Errno::EACCES => e
        raise Error, "cannot read sync state #{@path}: #{e.message}"
      end

      # Атомарно записывает манифест (создавая STATE_DIR).
      def save
        FileUtils.mkdir_p(@dir)
        tmp_path = File.join(@dir, "#{FILE_NAME}.#{SecureRandom.hex(8)}.tmp")
        File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |tmp|
          tmp.write(JSON.pretty_generate("version" => FORMAT_VERSION, "files" => @files.transform_values { |sha| { "sha256" => sha } }))
          tmp.write("\n")
        end
        File.rename(tmp_path, @path)
      rescue Errno::EEXIST, Errno::ENOTDIR, Errno::EISDIR, Errno::EROFS, Errno::EACCES, Errno::EPERM, Errno::ENOSPC, Errno::EDQUOT,
             Errno::EIO => e
        raise Error, "cannot write sync state #{@path}: #{e.message}"
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end

      private

      def parse(raw)
        payload = JSON.parse(raw)
        corrupt = ->(what) { raise Error, "sync state #{@path} is corrupt (#{what}); delete it to start over" }
        corrupt.call("not a JSON object") unless payload.is_a?(Hash)
        corrupt.call("unsupported version #{payload['version'].inspect}") unless payload["version"] == FORMAT_VERSION
        files = payload["files"]
        corrupt.call("\"files\" is not an object") unless files.is_a?(Hash)
        files.to_h do |key, entry|
          sha = entry["sha256"] if entry.is_a?(Hash)
          corrupt.call("bad entry for #{key.inspect}") unless key.is_a?(String) && sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/)

          [key, sha]
        end
      rescue JSON::ParserError => e
        raise Error, "sync state #{@path} is corrupt (#{e.message}); delete it to start over"
      end
    end
  end
end
