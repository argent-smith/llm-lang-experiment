# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox status: a dry run of push and pull. Compares the directory with
    # GET /blobs by key and SHA-256 and prints what push would upload and
    # what pull would download, by the same rules (a file whose contents
    # differ is listed both ways). Changes nothing on either side: the only
    # request is GET /blobs, and local files are only read.
    #
    #   upload    new      <key>   only here, the server lacks it
    #   upload    changed  <key>   the server's blob has other contents
    #   download  changed  <key>   the local file has other contents
    #   download  new      <key>   only on the server
    #   status: 2 to upload, 2 to download, 1 unchanged
    #
    # A local file that can't be read doesn't stop the comparison of the
    # others: the failures are reported together at the end, by raising
    # PartialFailure.
    class Status
      Change = Data.define(:direction, :kind, :key)
      Result = Data.define(:uploads, :downloads, :unchanged, :failed)

      def initialize(local_dir, remote, out: $stdout, err: $stderr)
        @local_dir = local_dir
        @remote = remote
        @out = out
        @err = err
      end

      def run
        failures = Failures.new
        entries = @local_dir.entries(on_error: ->(error) { failures.add(error.message) })
        blobs = @remote.list.sort_by { |blob| blob["key"] }
        remote_sha256 = blobs.to_h { |blob| [blob["key"], blob["sha256"]] }

        # A file that can't be read can't be compared: it is reported as a
        # failure and listed in neither direction.
        local_sha256 = {}
        unknown = Set.new
        entries.each do |entry|
          unknown << entry.key unless failures.guard { local_sha256[entry.key] = LocalDir.sha256(entry) }
        end

        # As push: every local file the server lacks or holds with other contents.
        uploads = local_sha256.filter_map do |key, sha256|
          next if remote_sha256[key] == sha256

          Change.new(direction: "upload", kind: remote_sha256.key?(key) ? "changed" : "new", key: key)
        end

        # As pull: every blob whose file is missing or has other contents,
        # skipping the keys pull would skip.
        unchanged = 0
        downloads = blobs.filter_map do |blob|
          next if unknown.include?(blob["key"]) || @local_dir.unreadable?(blob["key"])

          change = nil
          failures.guard do
            target = download_target(blob["key"])
            next unless target

            if target.stat.nil?
              change = Change.new(direction: "download", kind: "new", key: target.key)
            elsif local_sha256.fetch(target.key) { LocalDir.sha256(target) } == blob["sha256"]
              unchanged += 1
            else
              change = Change.new(direction: "download", kind: "changed", key: target.key)
            end
          end
          change
        end

        result = Result.new(uploads: uploads, downloads: downloads, unchanged: unchanged, failed: failures.size)
        report(result, failures)
        failures.raise_if_any("status")
        result
      end

      private

      # Where pull would write key, or nil if it would skip it (reported via
      # the directory's on_skip) or fail to write it (reported here).
      def download_target(key)
        @local_dir.target(key)
      rescue LocalDir::PathConflict => e
        @err.puts "syncbox: cannot download #{e.key}: #{e.reason}"
        nil
      end

      def report(result, failures)
        (result.uploads + result.downloads).each do |change|
          @out.puts format("%-9s %-8s %s", change.direction, change.kind, change.key)
        end
        if result.uploads.empty? && result.downloads.empty? && failures.empty?
          @out.puts "status: in sync, #{result.unchanged} unchanged"
        else
          @out.puts "status: #{result.uploads.size} to upload, #{result.downloads.size} to download, " \
                    "#{result.unchanged} unchanged#{failures.summary}"
        end
      end
    end
  end
end
