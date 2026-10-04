# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox pull: downloads every blob that is missing locally or whose
    # local copy has different contents (by SHA-256), to the file named by
    # its key inside the directory. Files identical to the server's version
    # are not downloaded again; local files the server doesn't have are left
    # alone.
    class Pull
      Result = Data.define(:downloaded, :unchanged)

      def initialize(local_dir, remote, out: $stdout)
        @local_dir = local_dir
        @remote = remote
        @out = out
      end

      def run
        @local_dir.real_root # fail before contacting the server
        downloaded = 0
        unchanged = 0
        @remote.list.each do |blob|
          target = @local_dir.target(blob["key"])
          next unless target

          if target.stat && same?(target, blob)
            unchanged += 1
            next
          end

          @local_dir.write(target) do |file|
            @remote.get(target.key) { |chunk| file.write(chunk) }
          end
          downloaded += 1
          @out.puts "downloaded #{target.key}"
        end

        Result.new(downloaded: downloaded, unchanged: unchanged).tap do |result|
          @out.puts "pull: #{result.downloaded} downloaded, #{result.unchanged} unchanged"
        end
      end

      private

      # Files of different sizes differ; only equal sizes need hashing.
      def same?(target, blob)
        return false if blob["size"].is_a?(Integer) && blob["size"] != target.stat.size

        LocalDir.sha256(target) == blob["sha256"]
      end
    end
  end
end
