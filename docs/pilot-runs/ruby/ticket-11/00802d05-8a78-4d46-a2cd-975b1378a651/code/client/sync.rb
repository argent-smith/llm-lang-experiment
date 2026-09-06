require "digest"
require "pathname"
require "fileutils"
require "time"
require_relative "push"
require_relative "manifest"
require_relative "failure_report"

module Syncbox
  module Sync
    module_function

    # Bidirectional push+pull in one pass (see "Правило разрешения
    # конфликтов для sync" in SYNCBOX-SPEC.md). Never deletes on either
    # side: a key missing from one side is only ever created on it, never
    # removed from the other.
    def run(config, out: $stdout, err: $stderr)
      base = Pathname.new(config.dir)
      unless base.directory?
        err.puts "syncbox: #{config.dir}: not a directory"
        return 1
      end

      client = ServerClient.new(config.server)

      begin
        remote_entries = client.list_blobs
      rescue ServerClient::ConnectionError, ServerClient::RequestError => e
        err.puts "syncbox: #{e.message}"
        return 1
      end

      remote = remote_entries.each_with_object({}) do |entry, h|
        h[entry["key"]] = entry unless Manifest.reserved?(entry["key"])
      end

      local = Push.local_files(base).each_with_object({}) do |path, h|
        key = path.relative_path_from(base).to_s
        h[key] = path unless Manifest.reserved?(key)
      end

      base_state = Manifest.load(base)
      new_state = {}
      uploaded = 0
      downloaded = 0
      skipped = 0
      failed = []

      (local.keys | remote.keys).sort.each do |key|
        local_path = local[key]
        remote_entry = remote[key]
        remote_sha = remote_entry && remote_entry["sha256"]

        begin
          local_sha = local_path && Digest::SHA256.file(local_path).hexdigest
        rescue SystemCallError => e
          failed << {key: key, message: e.message}
          next
        end

        action = classify(
          local_sha: local_sha, remote_sha: remote_sha, base_sha: base_state[key],
          local_mtime: local_path && local_path.mtime, remote_modified_at: remote_entry && remote_entry["modified_at"]
        )

        case action
        when :unchanged
          new_state[key] = local_sha
          skipped += 1
        when :push
          begin
            client.put_blob(key, local_path.binread)
            new_state[key] = local_sha
            uploaded += 1
            out.puts "uploaded #{key}"
          rescue ServerClient::ConnectionError, ServerClient::RequestError, SystemCallError => e
            failed << {key: key, message: e.message}
          end
        when :pull
          begin
            data = client.get_blob(key)
            local_target = base + key
            FileUtils.mkdir_p(local_target.dirname)
            local_target.binwrite(data)
            new_state[key] = remote_sha
            downloaded += 1
            out.puts "downloaded #{key}"
          rescue ServerClient::ConnectionError, ServerClient::RequestError, SystemCallError => e
            failed << {key: key, message: e.message}
          end
        end
      end

      Manifest.save(base, new_state)

      FailureReport.print(failed, err)

      summary = "sync complete: #{uploaded} uploaded, #{downloaded} downloaded, #{skipped} unchanged"
      summary += ", #{failed.size} failed" unless failed.empty?
      out.puts summary

      failed.empty? ? 0 : 1
    end

    # Pure decision for a single key. base_sha is nil when the key was
    # never part of a previously completed sync (including the very first
    # run). A real conflict - both sides moved away from base, or there's
    # no base to tell - falls back to the mtime rule; ties favor local.
    def classify(local_sha:, remote_sha:, base_sha:, local_mtime:, remote_modified_at:)
      return :none if local_sha.nil? && remote_sha.nil?
      return :push if remote_sha.nil?
      return :pull if local_sha.nil?
      return :unchanged if local_sha == remote_sha
      return :push if base_sha && base_sha == remote_sha
      return :pull if base_sha && base_sha == local_sha

      remote_time = Time.parse(remote_modified_at)
      local_mtime.to_i >= remote_time.to_i ? :push : :pull
    end
  end
end
