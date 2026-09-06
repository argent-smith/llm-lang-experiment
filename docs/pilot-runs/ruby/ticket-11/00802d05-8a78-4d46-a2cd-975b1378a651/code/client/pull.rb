require "digest"
require "pathname"
require "fileutils"
require_relative "manifest"
require_relative "failure_report"

module Syncbox
  module Pull
    module_function

    # Downloads every blob the server has whose SHA-256 doesn't match the
    # local copy under config.dir (or that's missing locally entirely).
    # Mirror image of Push.run: same key convention (relative POSIX path),
    # same exit-status contract (0 on full success, non-zero otherwise).
    def run(config, out: $stdout, err: $stderr)
      base = Pathname.new(config.dir)
      unless base.directory?
        err.puts "syncbox: #{config.dir}: not a directory"
        return 1
      end

      client = ServerClient.new(config.server)

      begin
        remote_blobs = client.list_blobs
      rescue ServerClient::ConnectionError, ServerClient::RequestError => e
        err.puts "syncbox: #{e.message}"
        return 1
      end

      downloaded = 0
      skipped = 0
      failed = []

      remote_blobs.each do |entry|
        key = entry["key"]
        next if Manifest.reserved?(key)

        local_path = base + key

        begin
          if local_path.file? && Digest::SHA256.file(local_path).hexdigest == entry["sha256"]
            skipped += 1
            next
          end

          data = client.get_blob(key)
          FileUtils.mkdir_p(local_path.dirname)
          local_path.binwrite(data)
          downloaded += 1
          out.puts "downloaded #{key}"
        rescue ServerClient::ConnectionError, ServerClient::RequestError, SystemCallError => e
          failed << {key: key, message: e.message}
        end
      end

      FailureReport.print(failed, err)

      summary = "pull complete: #{downloaded} downloaded, #{skipped} unchanged"
      summary += ", #{failed.size} failed" unless failed.empty?
      out.puts summary

      failed.empty? ? 0 : 1
    end
  end
end
