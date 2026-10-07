# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module Syncbox
  # Хранилище блобов поверх файловой системы: key — POSIX-путь относительно
  # корня data_dir, содержимое — файл по этому пути.
  #
  # Любой «мусорный» key обязан превращаться в InvalidKey (→ 400) или
  # NotFound (→ 404), а не в исключение сервера: контракт запрещает 5xx
  # на любом входе.
  class Store
    # Недопустимый key: traversal, абсолютный путь, непредставимое имя файла.
    class InvalidKey < StandardError; end

    # Блоба с таким key нет.
    class NotFound < StandardError; end

    # Служебный каталог для временных файлов атомарной записи. Лежит внутри
    # data_dir, чтобы rename был в пределах одной файловой системы; как key
    # это имя зарезервировано.
    TMP_DIR = ".syncbox-tmp"

    # Ограничения Linux на имя файла и путь (NAME_MAX / PATH_MAX).
    MAX_SEGMENT_BYTES = 255
    MAX_PATH_BYTES = 4095

    CHUNK_SIZE = 64 * 1024

    # Ошибки ФС, означающие, что key нельзя представить файлом на диске
    # (сегмент-файл на месте каталога, каталог на месте файла, слишком
    # длинное имя и т.п.). Всё остальное (EACCES, ENOSPC, EIO) — настоящие
    # сбои сервера, а не проблема входных данных.
    KEY_ERRORS = [
      Errno::ENAMETOOLONG, Errno::ENOTDIR, Errno::EISDIR, Errno::EEXIST,
      Errno::ENOTEMPTY, Errno::EINVAL, Errno::ELOOP
    ].freeze

    # Тело ответа Rack для отдачи файла по кускам; закрывает дескриптор по
    # требованию Rack (body.close).
    class FileBody
      def initialize(file)
        @file = file
      end

      def each
        while (chunk = @file.read(CHUNK_SIZE))
          yield chunk
        end
      end

      def close
        @file.close unless @file.closed?
      end
    end

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
    end

    # Проверяет key и возвращает его в виде строки UTF-8. Бросает InvalidKey.
    def validate_key(key)
      key = key.dup.force_encoding(Encoding::UTF_8)
      raise InvalidKey, "key must not be empty" if key.empty?
      raise InvalidKey, "key is not valid UTF-8" unless key.valid_encoding?
      raise InvalidKey, "key must not contain NUL" if key.include?("\0")
      raise InvalidKey, "key must be a relative path" if key.start_with?("/")

      segments = key.split("/", -1)
      segments.each do |segment|
        raise InvalidKey, "key must not contain empty path segments" if segment.empty?
        raise InvalidKey, "key must not contain '.' or '..' segments" if [".", ".."].include?(segment)
        raise InvalidKey, "path segment longer than #{MAX_SEGMENT_BYTES} bytes" if segment.bytesize > MAX_SEGMENT_BYTES
      end
      raise InvalidKey, "key uses reserved name #{TMP_DIR}" if segments.first == TMP_DIR
      raise InvalidKey, "key is too long" if File.join(@root, key).bytesize > MAX_PATH_BYTES

      key
    end

    # Атомарно записывает содержимое io под key: временный файл в TMP_DIR,
    # затем rename. Возвращает { "key", "sha256", "size" }.
    def put(key, io)
      key = validate_key(key)
      target = path_for(key)
      digest = Digest::SHA256.new
      size = 0

      tmp = create_tmp_file
      begin
        while (chunk = io.read(CHUNK_SIZE))
          tmp.write(chunk)
          digest.update(chunk)
          size += chunk.bytesize
        end
        tmp.close
        FileUtils.mkdir_p(File.dirname(target))
        File.rename(tmp.path, target)
      rescue *KEY_ERRORS => e
        raise InvalidKey, "key cannot be stored as a file: #{e.message}"
      ensure
        tmp.close unless tmp.closed?
        FileUtils.rm_f(tmp.path)
      end

      { "key" => key, "sha256" => digest.hexdigest, "size" => size }
    end

    # Открывает блоб на чтение; возвращает [size, FileBody]. Бросает NotFound.
    def open(key)
      key = validate_key(key)
      path = path_for(key)
      file = File.open(path, "rb")
      begin
        stat = file.stat
        raise NotFound, key unless stat.file?

        [stat.size, FileBody.new(file)]
      rescue StandardError
        file.close
        raise
      end
    rescue Errno::ENOENT, *KEY_ERRORS
      raise NotFound, key
    end

    # Удаляет блоб и опустевшие родительские каталоги. Бросает NotFound.
    def delete(key)
      key = validate_key(key)
      path = path_for(key)
      raise NotFound, key unless File.file?(path)

      File.delete(path)
      prune_empty_dirs(File.dirname(path))
      nil
    rescue Errno::ENOENT, *KEY_ERRORS
      raise NotFound, key
    end

    # Все блобы с метаданными, отсортированные по key.
    def list
      Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).filter_map do |rel|
        next if rel == "." || rel.start_with?("#{TMP_DIR}/") || rel == TMP_DIR

        key = begin
          validate_key(rel)
        rescue InvalidKey
          next
        end

        path = path_for(key)
        begin
          stat = File.stat(path)
          next unless stat.file?

          {
            "key" => key,
            "size" => stat.size,
            "sha256" => Digest::SHA256.file(path).hexdigest,
            "modified_at" => stat.mtime.utc.iso8601
          }
        rescue SystemCallError
          # файл исчез между glob и stat — просто не показываем
          next
        end
      end.sort_by { |meta| meta["key"] }
    end

    private

    def path_for(key)
      File.join(@root, key)
    end

    def create_tmp_file
      dir = File.join(@root, TMP_DIR)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, "#{SecureRandom.hex(16)}.tmp"),
                File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
    end

    def prune_empty_dirs(dir)
      while dir.start_with?("#{@root}/") && dir != @root
        Dir.rmdir(dir)
        dir = File.dirname(dir)
      end
    rescue SystemCallError
      # каталог не пуст или уже удалён параллельным запросом — на этом стоп
      nil
    end
  end
end
