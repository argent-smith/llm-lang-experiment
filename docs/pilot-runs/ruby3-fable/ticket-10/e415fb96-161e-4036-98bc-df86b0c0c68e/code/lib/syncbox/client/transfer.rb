# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module Syncbox
  module Client
    # Перенос одного файла между <dir> и сервером с проверкой целостности.
    # Общее для push, pull и sync.
    module Transfer
      # Временный файл скачивания: <каталог цели>/.syncbox-<hex>.tmp. Лежит
      # в том же каталоге, что и цель, — значит, на той же файловой системе,
      # и rename атомарен. Короткое случайное имя не зависит от длины имени
      # цели и не упирается в NAME_MAX.
      TMP_PREFIX = ".syncbox-"
      TMP_SUFFIX = ".tmp"

      # Ошибки ФС при записи скачанного файла, которые означают проблему с
      # конкретной целью, а не сбой программы.
      WRITE_ERRORS = [
        Errno::EEXIST, Errno::ENOTDIR, Errno::EISDIR, Errno::ENAMETOOLONG, Errno::EROFS, Errno::EACCES, Errno::EPERM,
        Errno::ENOSPC, Errno::EDQUOT, Errno::EIO
      ].freeze

      module_function

      # PUT /blobs/{key} телом из io (size байт) и сверка ответа сервера с
      # ожидаемыми sha256/size: расхождение значит, что файл изменился
      # между подсчётом хеша и загрузкой, и на сервере теперь лежит не то,
      # что решили загрузить. Возвращает size.
      def upload(api, key, io, size, sha256)
        meta = api.put_blob(key, io, size)
        unless meta["sha256"] == sha256 && meta["size"] == size
          raise Error, "PUT /blobs/#{key}: server stored sha256=#{meta['sha256']} size=#{meta['size']}, " \
                       "expected sha256=#{sha256} size=#{size} (file changed during upload?)"
        end

        size
      end

      # Скачивает блоб во временный файл в каталоге цели, сверяет хеш с
      # листингом и одним rename подставляет на место (прежний файл или
      # symlink заменяется целиком; права существующего файла, описанного
      # existing_stat, сохраняются). Возвращает размер в байтах. Временный
      # файл не переживает вызов ни в каком исходе, кроме убийства процесса.
      def download(api, key, expected_sha256, path, existing_stat, command: "pull")
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
                       "(blob changed on the server during #{command}?)"
        end

        File.chmod(existing_stat.mode & 0o7777, tmp_path) if existing_stat
        File.rename(tmp_path, path)
        size
      rescue *WRITE_ERRORS => e
        raise Error, "cannot write #{key}: #{e.message}"
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end
    end
  end
end
