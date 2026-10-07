# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module Syncbox
  module Client
    # syncbox pull <dir> --server <url>: скачать с сервера блобы, которых нет
    # в <dir> или которые отличаются от локального файла по SHA-256, и
    # записать их в <dir> по относительному пути, равному key. Файлы с
    # совпадающим хешем не скачиваются; локальные файлы, которых нет на
    # сервере, не трогаются — зеркало push.
    #
    # Порядок: проверка каталога, один GET /blobs, затем по каждому блобу в
    # порядке key: проверка key и локального пути → хеш локального файла →
    # при расхождении GET /blobs/{key} потоково во временный файл рядом с
    # целью → сверка хеша с листингом → rename на место. Первая же ошибка
    # (сетевая, неожиданный ответ, непригодный key, нечитаемый или
    # незаписываемый файл) прерывает команду — Client::Error наружу;
    # продолжение после частичного сбоя — тикет 11.
    class Pull
      CHUNK_SIZE = 64 * 1024

      # Временный файл скачивания: <каталог цели>/.syncbox-<hex>.tmp. Лежит
      # в том же каталоге, что и цель, — значит, на той же файловой системе,
      # и rename атомарен. Короткое случайное имя не зависит от длины имени
      # цели и не упирается в NAME_MAX.
      TMP_PREFIX = ".syncbox-"
      TMP_SUFFIX = ".tmp"

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
        @root = check_dir(@options.dir)
        summary = Summary.new(0, 0)

        Api.open(@options.server) do |api|
          blobs = api.list_blobs.sort_by { |meta| meta["key"].to_s }
          blobs.each do |meta|
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

      def check_dir(dir)
        root = File.expand_path(dir)
        raise Error, "directory not found: #{dir}" unless File.exist?(root)
        raise Error, "not a directory: #{dir}" unless File.directory?(root)

        root
      end

      # true, если блоб скачан; false, если локальный файл уже идентичен.
      def pull_blob(api, meta)
        key = meta["key"]
        remote_sha256 = meta["sha256"]
        unless key.is_a?(String) && remote_sha256.is_a?(String)
          raise Error, "GET /blobs: malformed entry in server listing: #{meta.inspect}"
        end

        path = local_path_for(key)
        stat = local_file_stat(key, path)
        if stat && local_sha256(path) == remote_sha256
          @out.puts "unchanged #{key}"
          return false
        end

        size = download(api, key, remote_sha256, path, stat)
        @out.puts "downloaded #{key} (#{size} bytes)"
        true
      end

      # Абсолютный локальный путь для key с сервера. Серверу не доверяем:
      # key проверяется так же строго, как сервер проверяет свой, и
      # дополнительно — каталог, в который ляжет файл (после нормализации и
      # разрешения символических ссылок в уже существующей части пути),
      # обязан оставаться внутри <dir>. Иначе блоб с сервера мог бы лечь
      # куда угодно на диске. Сам последний сегмент не разрешается: symlink
      # на его месте не пишется насквозь, а целиком заменяется файлом через
      # rename (см. #download), так что куда он ведёт — не важно.
      def local_path_for(key)
        reject = ->(reason) { raise Error, "refusing to pull #{key.inspect}: #{reason}" }
        key = key.dup.force_encoding(Encoding::UTF_8)
        reject.call("key is empty") if key.empty?
        reject.call("key is not valid UTF-8") unless key.valid_encoding?
        reject.call("key contains NUL") if key.include?("\0")
        reject.call("key is an absolute path") if key.start_with?("/")
        key.split("/", -1).each do |segment|
          reject.call("key contains an empty path segment") if segment.empty?
          reject.call("key contains a '.' or '..' segment") if [".", ".."].include?(segment)
        end

        path = File.join(@root, key)
        reject.call("key escapes #{@options.dir}") unless inside?(File.expand_path(path), @root)
        real_root = File.realpath(@root)
        resolved = resolve_existing_prefix(File.dirname(path), reject)
        reject.call("key resolves outside #{@options.dir} (through a symlink)") unless resolved == real_root || inside?(resolved, real_root)

        path
      end

      def inside?(path, root)
        path.start_with?(root.end_with?("/") ? root : "#{root}/")
      end

      # realpath самого длинного существующего префикса path.
      def resolve_existing_prefix(path, reject)
        current = path
        loop do
          return File.realpath(current)
        rescue Errno::ENOENT, Errno::ENOTDIR
          parent = File.dirname(current)
          raise if parent == current

          current = parent
        end
      rescue Errno::ELOOP
        reject.call("local path goes through a symlink loop")
      end

      # stat локального файла под key (по цели, если это symlink) или nil,
      # если его нет. Каталог или не-файл на месте цели — ошибка: молча
      # заменить их блобом нельзя.
      def local_file_stat(key, path)
        stat = File.stat(path)
        return stat if stat.file?

        raise Error, "cannot write #{key}: a #{stat.ftype} is in the way at #{path}"
      rescue Errno::ENOENT
        # либо файла нет, либо это битый symlink — в обоих случаях скачиваем,
        # rename подставит обычный файл на место
        nil
      rescue Errno::ENOTDIR
        raise Error, "cannot write #{key}: a parent of #{path} is not a directory"
      end

      def local_sha256(path)
        File.open(path, "rb") { |file| digest_io(file) }
      end

      def digest_io(io)
        digest = Digest::SHA256.new
        while (chunk = io.read(CHUNK_SIZE))
          digest.update(chunk)
        end
        digest.hexdigest
      end

      # Скачивает блоб во временный файл в каталоге цели, сверяет хеш с
      # листингом и одним rename подставляет на место (прежний файл или
      # symlink заменяется целиком; права существующего файла сохраняются).
      # Возвращает размер в байтах. Временный файл не переживает вызов ни в
      # каком исходе, кроме убийства процесса.
      def download(api, key, expected_sha256, path, existing_stat)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp_path = File.join(dir, "#{TMP_PREFIX}#{SecureRandom.hex(8)}#{TMP_SUFFIX}")
        digest = Digest::SHA256.new
        size = File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |tmp|
          api.get_blob(key) do |chunk|
            tmp.write(chunk)
            digest.update(chunk)
          end
        end

        sha256 = digest.hexdigest
        unless sha256 == expected_sha256
          raise Error, "GET /blobs/#{key}: downloaded sha256=#{sha256} (#{size} bytes), listing says sha256=#{expected_sha256} " \
                       "(blob changed on the server during pull?)"
        end

        File.chmod(existing_stat.mode & 0o7777, tmp_path) if existing_stat
        File.rename(tmp_path, path)
        size
      rescue Errno::EEXIST, Errno::ENOTDIR, Errno::EISDIR, Errno::ENAMETOOLONG, Errno::EROFS, Errno::EACCES, Errno::EPERM,
             Errno::ENOSPC, Errno::EDQUOT, Errno::EIO => e
        raise Error, "cannot write #{key}: #{e.message}"
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end
    end
  end
end
