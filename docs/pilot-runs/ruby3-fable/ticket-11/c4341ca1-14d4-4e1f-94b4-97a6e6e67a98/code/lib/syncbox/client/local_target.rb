# frozen_string_literal: true

module Syncbox
  module Client
    # Куда в <dir> ложится блоб с сервера: проверка key и локального пути.
    # Общее для pull и sync.
    module LocalTarget
      module_function

      # Абсолютный локальный путь для key с сервера (root — абсолютный путь
      # <dir>, dir — как его назвал пользователь, для сообщений; command —
      # имя команды для «refusing to <command>»). Серверу не доверяем: key
      # проверяется так же строго, как сервер проверяет свой, и
      # дополнительно — каталог, в который ляжет файл (после нормализации и
      # разрешения символических ссылок в уже существующей части пути),
      # обязан оставаться внутри <dir>. Иначе блоб с сервера мог бы лечь
      # куда угодно на диске. Сам последний сегмент не разрешается: symlink
      # на его месте не пишется насквозь, а целиком заменяется файлом через
      # rename (см. Transfer.download), так что куда он ведёт — не важно.
      def path_for(root, dir, key, command:)
        reject = ->(reason) { raise Error, "refusing to #{command} #{key.inspect}: #{reason}" }
        key = key.dup.force_encoding(Encoding::UTF_8)
        reject.call("key is empty") if key.empty?
        reject.call("key is not valid UTF-8") unless key.valid_encoding?
        reject.call("key contains NUL") if key.include?("\0")
        reject.call("key is an absolute path") if key.start_with?("/")
        key.split("/", -1).each do |segment|
          reject.call("key contains an empty path segment") if segment.empty?
          reject.call("key contains a '.' or '..' segment") if [".", ".."].include?(segment)
        end

        path = File.join(root, key)
        reject.call("key escapes #{dir}") unless inside?(File.expand_path(path), root)
        real_root = File.realpath(root)
        resolved = resolve_existing_prefix(File.dirname(path), reject)
        reject.call("key resolves outside #{dir} (through a symlink)") unless resolved == real_root || inside?(resolved, real_root)

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
      def file_stat(key, path)
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
    end
  end
end
