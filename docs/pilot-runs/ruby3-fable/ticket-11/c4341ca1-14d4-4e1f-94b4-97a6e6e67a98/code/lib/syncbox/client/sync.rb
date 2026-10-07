# frozen_string_literal: true

require "time"

module Syncbox
  module Client
    # syncbox sync <dir> --server <url>: двунаправленная синхронизация —
    # push и pull в один проход плюс разрешение конфликтов.
    #
    # По каждому key из объединения локальных файлов и листинга сервера:
    #   - есть только локально → PUT (как push);
    #   - есть только на сервере → GET и запись в <dir> (как pull);
    #   - SHA-256 совпадают → ничего;
    #   - отличаются, и относительно последнего известного общего состояния
    #     (SyncState) изменилась одна сторона → переносится её версия;
    #   - отличаются, и изменились обе стороны (или общее состояние для key
    #     неизвестно — так на первом запуске) → конфликт: побеждает версия с
    #     более свежим mtime (локальный mtime из ФС против modified_at из
    #     листинга сервера), при равенстве — локальная. Времена сравниваются
    #     с точностью, с которой сервер отдаёт modified_at (целые секунды):
    #     локальный mtime округляется вниз до неё, иначе доли секунды, которые
    #     сервер отбросил, выглядели бы как «локальная новее».
    # sync ничего не удаляет ни локально, ни на сервере: файл, исчезнувший с
    # одной стороны, снова переносится с другой.
    #
    # Порядок: обход каталога и чтение SyncState (ошибки обхода и манифеста —
    # до первого обращения к сети), один GET /blobs (его сбой или битая
    # запись в листинге прерывают команду), затем по каждому key в порядке
    # key — хеш локального файла, решение и перенос. Сбой одного key
    # (нечитаемый или незаписываемый файл, сервер ответил не тем кодом,
    # оборвал соединение или не ответил в срок, непригодный key или
    # modified_at) команду не прерывает: он учитывается (Failures), остальные
    # key обрабатываются, в конце — сводный отчёт и PartialFailure.
    # Недоступность сервера — ServerUnreachable наружу сразу. Общее состояние
    # обновляется по мере переноса (упавшие key остаются с прежним) и
    # записывается в конце — и при прерывании, для уже перенесённых файлов.
    class Sync
      LocalFile = Struct.new(:path, :sha256, :size, :mtime)
      RemoteFile = Struct.new(:sha256, :size, :modified_at)

      # Решение по одному key: action — :upload/:download/:unchanged, reason —
      # текст для вывода, conflict — true, если решал mtime.
      Decision = Struct.new(:action, :reason, :conflict)

      Summary = Struct.new(:uploaded, :downloaded, :unchanged, :conflicts, :failed) do
        def total
          uploaded + downloaded + unchanged + failed
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
        @root = LocalTree.check_dir(@options.dir)
        entries = scan_local
        state = SyncState.load(@root)
        base = state.to_h
        summary = Summary.new(0, 0, 0, 0, 0)
        failures = Failures.new("sync", err: @err)
        keys = nil
        aborted = true

        begin
          Api.open(@options.server) do |api|
            remote = index_listing(api.list_blobs)
            keys = (entries.keys | remote.keys).sort
            keys.each do |key|
              next if failures.attempt(key) { sync_key(api, key, entries[key], remote[key], base, summary) }

              summary.failed += 1
              @out.puts "failed #{Failures.display_key(key)}"
            end
          end
          aborted = false
        ensure
          # Что перенесено, то уже общее — запоминаем и при прерывании, чтобы
          # следующий sync не принял доделанную часть за конфликт. Упавшие key
          # остаются с прежним состоянием, ключи, исчезнувшие с обеих сторон,
          # из состояния уходят.
          persist(state, base.slice(*keys), quiet: aborted) if keys
        end

        @out.puts summary_line(summary)
        failures.check!(summary.total)
        summary
      end

      private

      # key → LocalTree::Entry для всех файлов <dir>; хеши считаются позже,
      # по одному key, чтобы нечитаемый файл был сбоем только этого key.
      def scan_local
        entries = LocalTree.scan(@options.dir) do |rel, reason|
          @err.puts "syncbox: skipping #{rel}: #{reason}"
        end
        entries.to_h { |entry| [entry.key, entry] }
      end

      # key → RemoteFile из листинга сервера. Серверу не доверяем: запись без
      # строковых key/sha256 — ошибка; зарезервированные key пропускаются.
      def index_listing(list)
        remote = {}
        list.each do |meta|
          key = meta["key"] if meta.is_a?(Hash)
          sha256 = meta["sha256"] if meta.is_a?(Hash)
          raise Error, "GET /blobs: malformed entry in server listing: #{meta.inspect}" unless key.is_a?(String) && sha256.is_a?(String)

          if Client.reserved_key?(key)
            @err.puts "syncbox: skipping #{key}: #{Client.reserved_key_reason}"
            next
          end
          remote[key] = RemoteFile.new(sha256, meta["size"], meta["modified_at"])
        end
        remote
      end

      # Один key целиком: хеш локального файла → решение → перенос → общее
      # состояние. Любой сбой на этом пути — сбой только этого key.
      def sync_key(api, key, entry, remote, base, summary)
        local = local_file(entry)
        decision = decide(key, local, remote, base[key])
        apply(api, key, decision, local, remote, summary)
        base[key] = (decision.action == :download ? remote : local).sha256
      end

      # LocalFile для записи обхода (хеш и mtime считаются здесь) или nil.
      def local_file(entry)
        return nil if entry.nil?

        sha256, size = LocalTree.digest(entry.path)
        LocalFile.new(entry.path, sha256, size, File.stat(entry.path).mtime)
      end

      def decide(key, local, remote, base_sha256)
        return Decision.new(:upload, "only local", false) if remote.nil?
        return Decision.new(:download, "only on server", false) if local.nil?
        return Decision.new(:unchanged, nil, false) if local.sha256 == remote.sha256

        if base_sha256
          return Decision.new(:download, "changed on server", false) if local.sha256 == base_sha256
          return Decision.new(:upload, "changed locally", false) if remote.sha256 == base_sha256
        end

        resolve_conflict(key, local, remote, never_synced: base_sha256.nil?)
      end

      # Правило спецификации: побеждает более свежий mtime, при равенстве —
      # локальная версия.
      def resolve_conflict(key, local, remote, never_synced:)
        remote_time, digits = parse_modified_at(key, remote.modified_at)
        local_time = floor_to(local.mtime, digits)
        remote_text = remote_time.utc.iso8601(digits)
        local_text = local_time.utc.iso8601(digits)
        prefix = never_synced ? "conflict, never synced before" : "conflict"

        if remote_time > local_time
          Decision.new(:download, "#{prefix}: server #{remote_text} is newer than local #{local_text}", true)
        elsif local_time > remote_time
          Decision.new(:upload, "#{prefix}: local #{local_text} is newer than server #{remote_text}", true)
        else
          Decision.new(:upload, "#{prefix}: same mtime #{local_text}, local wins", true)
        end
      end

      # [Time, число знаков после запятой в modified_at сервера].
      def parse_modified_at(key, value)
        raise Error, "GET /blobs: entry #{key.inspect} has no modified_at, cannot resolve the conflict" unless value.is_a?(String)

        digits = value[/\.(\d+)(?=Z|[+-]\d{2}:?\d{2}\z)/, 1]&.length || 0
        [Time.iso8601(value), digits]
      rescue ArgumentError => e
        raise Error, "GET /blobs: entry #{key.inspect} has malformed modified_at #{value.inspect}: #{e.message}"
      end

      def floor_to(time, digits)
        scale = 10**digits
        Time.at(Rational((time.to_r * scale).floor, scale)).utc
      end

      # Конфликт считается разрешённым только после успешного переноса.
      def apply(api, key, decision, local, remote, summary)
        case decision.action
        when :upload
          size = upload(api, key, local)
          summary.uploaded += 1
          @out.puts "uploaded #{key} (#{size} bytes; #{decision.reason})"
        when :download
          size = download(api, key, remote)
          summary.downloaded += 1
          @out.puts "downloaded #{key} (#{size} bytes; #{decision.reason})"
        else
          summary.unchanged += 1
          @out.puts "unchanged #{key}"
        end
        summary.conflicts += 1 if decision.conflict
      end

      # PUT локального файла. Размер берётся с открытого дескриптора; если
      # файл изменился после подсчёта хеша, хеш в ответе сервера разойдётся с
      # решённым и Transfer.upload поднимет ошибку.
      def upload(api, key, local)
        File.open(local.path, "rb") do |file|
          Transfer.upload(api, key, file, file.stat.size, local.sha256)
        end
      end

      def download(api, key, remote)
        path = LocalTarget.path_for(@root, @options.dir, key, command: "sync")
        stat = LocalTarget.file_stat(key, path)
        Transfer.download(api, key, remote.sha256, path, stat, command: "sync")
      end

      # Записывает общее состояние, если оно изменилось. При quiet (команда
      # уже прерывается другой ошибкой) сбой записи — предупреждение в
      # stderr, а не замена исходной ошибки.
      def persist(state, files, quiet:)
        return unless state.replace(files)

        state.save
      rescue Error, SystemCallError => e
        raise unless quiet

        @err.puts "syncbox: warning: #{e.message}"
      end

      def summary_line(summary)
        if summary.failed.zero?
          "sync complete: #{summary.uploaded} uploaded, #{summary.downloaded} downloaded, " \
            "#{summary.unchanged} unchanged, #{summary.total} files total, #{summary.conflicts} conflicts resolved"
        else
          "sync incomplete: #{summary.uploaded} uploaded, #{summary.downloaded} downloaded, " \
            "#{summary.unchanged} unchanged, #{summary.failed} failed, #{summary.total} files total, " \
            "#{summary.conflicts} conflicts resolved"
        end
      end
    end
  end
end
