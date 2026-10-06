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
  #
  # Защита от directory traversal — двухслойная:
  #   1. #validate_key — лексическая проверка декодированного key: только
  #      относительный путь из непустых сегментов без `.`/`..`, валидный
  #      UTF-8 без NUL, в пределах NAME_MAX/PATH_MAX;
  #   2. #path_for — проверка итогового пути на диске: после нормализации и
  #      разрешения символических ссылок он обязан оставаться строго внутри
  #      корня хранилища. Это ловит то, чего не видно в тексте key: symlink
  #      внутри data_dir, ведущий наружу, или корень, сам являющийся ссылкой.
  #
  # Запись атомарна: PUT никогда не пишет в целевой файл напрямую — тело
  # уходит во временный файл в TMP_DIR и одним rename подставляется под key
  # (см. #put). Координации между процессами нет: процесс сервера один,
  # атомарность даёт файловая система.
  class Store
    # Недопустимый key: traversal, абсолютный путь, непредставимое имя файла.
    class InvalidKey < StandardError; end

    # Блоба с таким key нет.
    class NotFound < StandardError; end

    # Служебный каталог для временных файлов атомарной записи. Лежит внутри
    # data_dir, чтобы rename был в пределах одной файловой системы; как key
    # это имя зарезервировано.
    TMP_DIR = ".syncbox-tmp"

    # Суффикс временных файлов (<hex>.tmp): по нему при старте распознаются
    # остатки от процесса, убитого посреди PUT.
    TMP_SUFFIX = ".tmp"

    # Ограничения Linux на имя файла и путь (NAME_MAX / PATH_MAX).
    MAX_SEGMENT_BYTES = 255
    MAX_PATH_BYTES = 4095

    CHUNK_SIZE = 64 * 1024

    # Сколько раз PUT повторяет rename, если параллельный DELETE успел удалить
    # опустевший родительский каталог между mkdir_p и rename.
    RENAME_ATTEMPTS = 5

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

    # Запись кэша контрольных сумм: sha256 действителен, пока файл на диске
    # тот же самый (устройство, inode, размер, mtime с наносекундами).
    DigestEntry = Struct.new(:dev, :ino, :size, :mtime, :sha256) do
      def matches?(stat)
        dev == stat.dev && ino == stat.ino && size == stat.size && mtime == stat.mtime
      end
    end

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
      # key => DigestEntry. Хеш считается при PUT и переиспользуется в #list,
      # пока файл не изменился; файлы, появившиеся на диске мимо сервера,
      # хешируются при первом листинге.
      @digests = {}
      @digests_lock = Mutex.new
      # Остатки от процесса, убитого посреди PUT: в этом процессе
      # незавершённых записей ещё нет, так что всё в TMP_DIR — мусор.
      remove_stale_tmp_files
    end

    # Лексическая проверка key (первый слой защиты от traversal). Возвращает
    # key в виде строки UTF-8, бросает InvalidKey.
    #
    # Проверяется уже декодированный key, поэтому percent-encoded варианты
    # (`%2e%2e`, `%2f`) и смешанные (`..%2fx`) приходят сюда теми же байтами,
    # что и «открытые», и отсекаются той же проверкой по сегментам. Текст key
    # при этом не нормализуется (ничего не вырезается и не схлопывается):
    # либо он корректен как есть, либо отклоняется целиком.
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

    # Атомарно записывает содержимое io под key и возвращает
    # { "key", "sha256", "size" }.
    #
    # В целевой файл никогда не пишется напрямую: тело целиком уходит во
    # временный файл в TMP_DIR (та же файловая система, что и target —
    # каталог лежит внутри root), сбрасывается на диск и одним rename
    # подставляется под key. Для читателя под key в любой момент лежит либо
    # прежний файл целиком, либо новый целиком; уже открытый дескриптор
    # дочитывает прежнюю версию, даже если её успели заменить. У параллельных
    # PUT по одному key свои временные файлы: под key остаётся версия, чей
    # rename был последним, а каждый ответ описывает именно своё тело.
    #
    # Временный файл не переживает запрос ни в каком исходе: успешный rename
    # забирает его, при ошибке (недопустимый key, обрыв чтения io, сбой ФС)
    # его удаляет ensure.
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
        flush_to_disk(tmp)
        tmp.close
        # rename сохраняет inode и mtime, поэтому stat временного файла
        # описывает и будущий файл под key — им и валидируется кэш хешей.
        stat = File.stat(tmp.path)
        move_into_place(tmp.path, target)
      rescue *KEY_ERRORS => e
        raise InvalidKey, "key cannot be stored as a file: #{e.message}"
      rescue Errno::EXDEV => e
        # Внутри каталога данных смонтирована другая ФС: rename туда невозможен,
        # а копирование не было бы атомарным. Это сбой конфигурации, не key.
        raise e.class, "#{TMP_DIR} and #{File.dirname(target)} are on different filesystems, " \
                       "atomic rename is impossible (#{e.message})"
      ensure
        tmp.close unless tmp.closed?
        FileUtils.rm_f(tmp.path)
      end

      sha256 = digest.hexdigest
      remember_digest(key, stat, sha256)
      { "key" => key, "sha256" => sha256, "size" => size }
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

    # Удаляет блоб. Бросает NotFound, если под key нет обычного файла
    # (в том числе если key — каталог).
    #
    # Опустевшие родительские каталоги удаляются вместе с блобом: иначе после
    # DELETE «d/e/f» key «d» навсегда остался бы занят пустым каталогом и
    # PUT «d» отвечал бы 400. Удалённый блоб сразу исчезает из #list — список
    # строится по файловой системе, а кэш хешей для key сбрасывается.
    def delete(key)
      key = validate_key(key)
      path = path_for(key)
      raise NotFound, key unless File.file?(path)

      File.delete(path)
      forget_digest(key)
      prune_empty_dirs(File.dirname(path))
      nil
    rescue Errno::ENOENT, *KEY_ERRORS
      raise NotFound, key
    end

    # Все блобы с метаданными, отсортированные по key:
    #   { "key", "size", "sha256", "modified_at" (ISO 8601 UTC) }.
    #
    # Источник истины — файловая система: обходятся все обычные файлы под
    # root, включая вложенные каталоги и dot-файлы. Пропускается всё, что не
    # может быть блобом: каталоги, FIFO и прочие не-файлы, служебный
    # TMP_DIR, имена, не представимые как key (например, невалидный UTF-8).
    def list
      entries = {}
      Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).each do |rel|
        key = key_for_entry(rel)
        next unless key

        meta = metadata(key)
        entries[key] = meta if meta
      end
      @digests_lock.synchronize { @digests.keep_if { |key, _| entries.key?(key) } }
      entries.keys.sort.map { |key| entries[key] }
    end

    # Удаляет из TMP_DIR временные файлы, оставшиеся от предыдущего процесса
    # сервера (убит посреди PUT): живой процесс свои временные файлы убирает
    # сам, а другой процесс на том же каталоге данных спецификацией не
    # предусмотрен. Вызывается при создании хранилища, когда незавершённых
    # PUT ещё нет. Трогает только файлы с TMP_SUFFIX; ничего не создаёт.
    # Возвращает число удалённых файлов.
    def remove_stale_tmp_files
      dir = File.join(@root, TMP_DIR)
      Dir.children(dir).count do |name|
        next false unless name.end_with?(TMP_SUFFIX)

        File.delete(File.join(dir, name))
        true
      rescue SystemCallError
        false # уже удалён или это не файл — не наш
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      0
    end

    private

    # key для записи, найденной на диске, или nil, если её нельзя адресовать
    # через API ("." от glob, TMP_DIR, недопустимые имена).
    def key_for_entry(rel)
      validate_key(rel)
    rescue InvalidKey
      nil
    end

    # Метаданные блоба или nil, если под key нет обычного файла.
    #
    # size, mtime и sha256 берутся с одного открытого дескриптора: даже если
    # параллельный PUT подменит файл через rename, метаданные останутся
    # согласованными между собой (опишут старую версию целиком).
    # NONBLOCK — чтобы открытие FIFO не повисло; на обычные файлы не влияет.
    def metadata(key)
      File.open(path_for(key), File::RDONLY | File::NONBLOCK | File::BINARY) do |file|
        stat = file.stat
        return nil unless stat.file?

        sha256 = cached_digest(key, stat) || digest_of(file)
        remember_digest(key, stat, sha256)
        {
          "key" => key,
          "size" => stat.size,
          "sha256" => sha256,
          "modified_at" => stat.mtime.utc.iso8601
        }
      end
    rescue SystemCallError
      # файл исчез между glob и open, либо это сокет/устройство — не блоб
      nil
    rescue InvalidKey
      # symlink, ведущий за пределы корня хранилища, — не блоб
      nil
    end

    def digest_of(file)
      digest = Digest::SHA256.new
      while (chunk = file.read(CHUNK_SIZE))
        digest.update(chunk)
      end
      digest.hexdigest
    end

    def cached_digest(key, stat)
      @digests_lock.synchronize do
        entry = @digests[key]
        entry.sha256 if entry&.matches?(stat)
      end
    end

    def remember_digest(key, stat, sha256)
      entry = DigestEntry.new(stat.dev, stat.ino, stat.size, stat.mtime, sha256)
      @digests_lock.synchronize { @digests[key] = entry }
    end

    def forget_digest(key)
      @digests_lock.synchronize { @digests.delete(key) }
    end

    # Абсолютный путь файла для уже проверенного key (второй слой защиты от
    # traversal). Путь обязан оставаться строго внутри корня хранилища и после
    # лексической нормализации, и после разрешения символических ссылок —
    # иначе InvalidKey. Не полагается на то, что validate_key уже отсеял
    # `..`: даже если бы текстовая проверка что-то пропустила, наружу путь не
    # выйдет.
    #
    # Ссылки разрешаются через realpath самого длинного существующего префикса
    # пути: сам файл при PUT может ещё не существовать, а при GET/DELETE —
    # отсутствовать (→ 404); несуществующий хвост ссылок содержать не может.
    # Symlink, остающийся внутри корня, допустим.
    def path_for(key)
      path = File.join(@root, key)
      raise InvalidKey, "key escapes the storage root" unless strictly_inside?(File.expand_path(path), @root)

      root = real_root # сначала: подъём по префиксам должен остановиться на существующем корне
      resolved = resolve_existing_prefix(path)
      raise InvalidKey, "key resolves outside the storage root" unless resolved == root || strictly_inside?(resolved, root)

      path
    end

    def strictly_inside?(path, root)
      path.start_with?(root.end_with?("/") ? root : "#{root}/")
    end

    # realpath самого длинного существующего префикса path (вплоть до корня).
    def resolve_existing_prefix(path)
      current = path
      loop do
        return File.realpath(current)
      rescue Errno::ENOENT, Errno::ENOTDIR
        parent = File.dirname(current)
        raise if parent == current

        current = parent
      end
    rescue Errno::ELOOP
      raise InvalidKey, "key resolves through a symlink loop"
    rescue *KEY_ERRORS => e
      raise InvalidKey, "key cannot be resolved to a file: #{e.message}"
    end

    # Канонический путь корня хранилища. Корень создаётся, если его нет: иначе
    # ни один key нельзя было бы проверить, а PUT и так создаёт каталоги.
    def real_root
      File.realpath(@root)
    rescue Errno::ENOENT
      FileUtils.mkdir_p(@root)
      File.realpath(@root)
    end

    # Переносит временный файл под целевой путь, создавая родительские
    # каталоги. Параллельный DELETE соседнего блоба может удалить только что
    # созданный пустой каталог до rename (см. #prune_empty_dirs) — тогда
    # rename даёт ENOENT, и попытка повторяется с новым mkdir_p.
    def move_into_place(src, target)
      attempts = 0
      begin
        ensure_parent_dir(target)
        File.rename(src, target)
      rescue Errno::ENOENT
        attempts += 1
        raise if attempts >= RENAME_ATTEMPTS

        retry
      end
    end

    def ensure_parent_dir(target)
      FileUtils.mkdir_p(File.dirname(target))
    end

    # Временный файл с уникальным случайным именем: параллельные PUT (по
    # одному или разным key) пишут каждый в свой файл и не мешают друг другу.
    def create_tmp_file
      dir = File.join(@root, TMP_DIR)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, "#{SecureRandom.hex(16)}#{TMP_SUFFIX}"),
                File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
    end

    # Сбрасывает данные временного файла на диск до rename. Без этого после
    # сбоя питания под key мог бы оказаться пустой или обрезанный файл: rename
    # уже в журнале ФС, а данные ещё нет. Файловые системы без поддержки
    # fsync — не ошибка записи.
    def flush_to_disk(file)
      file.fsync
    rescue Errno::EINVAL, Errno::ENOTSUP, NotImplementedError
      nil
    end

    # Удаляет каталог и его опустевших предков вверх до корня хранилища
    # (сам корень не трогает). Останавливается на первом непустом каталоге.
    def prune_empty_dirs(dir)
      while dir.start_with?("#{@root}/")
        Dir.rmdir(dir)
        dir = File.dirname(dir)
      end
    rescue SystemCallError
      # каталог не пуст или уже удалён параллельным запросом — на этом стоп
      nil
    end
  end
end
