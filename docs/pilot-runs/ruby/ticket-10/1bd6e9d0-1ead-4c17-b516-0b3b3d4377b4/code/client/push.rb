require "find"
require "digest"
require "pathname"
require_relative "manifest"

module Syncbox
  module Push
    module_function

    # Uploads every file under config.dir whose SHA-256 doesn't match the
    # server's copy (or that the server doesn't have at all). Returns a
    # process exit status (0 on full success, non-zero otherwise) rather
    # than raising, so callers (the syncbox executable) can just `exit` it.
    def run(config, out: $stdout, err: $stderr)
      base = Pathname.new(config.dir)
      unless base.directory?
        err.puts "syncbox: #{config.dir}: not a directory"
        return 1
      end

      client = ServerClient.new(config.server)

      begin
        remote_sha = client.list_blobs.each_with_object({}) { |entry, h| h[entry["key"]] = entry["sha256"] }
      rescue ServerClient::ConnectionError, ServerClient::RequestError => e
        err.puts "syncbox: #{e.message}"
        return 1
      end

      uploaded = 0
      skipped = 0
      failed = []

      local_files(base).each do |path|
        key = path.relative_path_from(base).to_s
        sha256 = Digest::SHA256.file(path).hexdigest

        if remote_sha[key] == sha256
          skipped += 1
          next
        end

        begin
          client.put_blob(key, path.binread)
          uploaded += 1
          out.puts "uploaded #{key}"
        rescue ServerClient::ConnectionError => e
          err.puts "syncbox: #{e.message}"
          return 1
        rescue ServerClient::RequestError => e
          err.puts "syncbox: #{key}: #{e.message}"
          failed << key
        end
      end

      summary = "push complete: #{uploaded} uploaded, #{skipped} unchanged"
      summary += ", #{failed.size} failed" unless failed.empty?
      out.puts summary

      failed.empty? ? 0 : 1
    end

    # Excludes Manifest::DIR (sync's own bookkeeping, see manifest.rb) so
    # it's never treated as a regular file to push/compare/report.
    def local_files(base)
      Find.find(base.to_s).each_with_object([]) do |entry, files|
        path = Pathname.new(entry)
        next unless path.file?
        next if Manifest.reserved?(path.relative_path_from(base).to_s)

        files << path
      end.sort
    end
  end
end
