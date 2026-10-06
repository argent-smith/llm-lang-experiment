# frozen_string_literal: true

module Syncbox
  module Client
    # Рекурсивный обход локального каталога. Каждому обычному файлу
    # соответствует key — его относительный POSIX-путь внутри каталога, та же
    # конвенция, что у сервера (docs/readme.txt).
    #
    # В обход попадают обычные файлы (включая dot-файлы) и символические
    # ссылки на обычные файлы (по содержимому цели). Не попадают, с
    # предупреждением через блок: ссылки на каталоги (не разворачиваются,
    # чтобы не зациклиться и не утащить лишнее), битые ссылки, FIFO, сокеты
    # и прочие не-файлы. Имя, которое нельзя выразить как key (невалидный
    # UTF-8), — ошибка: такой файл сервер принять не сможет.
    module LocalTree
      Entry = Struct.new(:key, :path)

      module_function

      # Возвращает массив Entry, отсортированный по key. Блок (если дан)
      # получает (относительный путь, причина) для каждого пропущенного элемента.
      def scan(dir, &on_skip)
        root = File.expand_path(dir)
        raise Error, "directory not found: #{dir}" unless File.exist?(root)
        raise Error, "not a directory: #{dir}" unless File.directory?(root)

        entries = []
        walk(root, "", entries, on_skip)
        entries.sort_by!(&:key)
      end

      def walk(root, prefix, entries, on_skip)
        dir = prefix.empty? ? root : File.join(root, prefix)
        Dir.children(dir).sort.each do |name|
          rel = prefix.empty? ? name : "#{prefix}/#{name}"
          path = File.join(root, rel)
          stat = File.lstat(path)
          if stat.symlink?
            stat = begin
              File.stat(path)
            rescue SystemCallError => e
              on_skip&.call(rel, "broken symlink (#{e.message})")
              next
            end
            if stat.directory?
              on_skip&.call(rel, "symlink to a directory is not followed")
              next
            end
          elsif stat.directory?
            walk(root, rel, entries, on_skip)
            next
          end

          unless stat.file?
            on_skip&.call(rel, "not a regular file (#{stat.ftype})")
            next
          end

          entries << Entry.new(key_for(rel), path)
        end
      end

      # key для относительного пути: строка UTF-8, иначе Error.
      def key_for(rel)
        key = rel.dup.force_encoding(Encoding::UTF_8)
        raise Error, "cannot use #{rel.b.inspect} as a blob key: file name is not valid UTF-8" unless key.valid_encoding?

        key
      end
    end
  end
end
