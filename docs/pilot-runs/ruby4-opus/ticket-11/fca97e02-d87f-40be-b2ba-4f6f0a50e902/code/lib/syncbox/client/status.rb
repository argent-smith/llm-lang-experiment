# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox status: a dry run. Compares the local directory with the
    # server's blob list by key and SHA-256, the way push and pull do, and
    # prints what each of them would transfer:
    #
    #   upload (not on server): docs/new.txt
    #   upload (content differs): notes.txt
    #   download (not local): photos/cat.jpg
    #   download (content differs): notes.txt
    #   status: 2 to upload, 2 to download, 3 up to date
    #
    # A file whose content differs is listed in both directions: push would
    # upload it and pull would download it (which side wins is up to sync).
    #
    # Changes nothing on either side: the only request made is GET /blobs,
    # and local files are only read. A file that cannot be compared does not
    # stop the others (Failures).
    class Status
      # Why a file would be transferred.
      NOT_ON_SERVER = "not on server"
      NOT_LOCAL = "not local"
      DIFFERS = "content differs"

      def initialize(dir, remote, out:, err:)
        @dir = dir
        @remote = remote
        @out = out
        @err = err
      end

      def run
        raise Error, "not a directory: #{@dir}" unless File.directory?(@dir)

        failures = Failures.new("status")
        skipped = Set.new
        files = LocalTree.new(@dir).files(failures: failures) do |key, reason|
          skipped << key
          @err.puts "syncbox: skipping #{key}: #{reason}"
        end
        blobs = @remote.list
        Pull.check_keys(blobs.values)

        # [key, reason] pairs.
        uploads = []
        downloads = []
        up_to_date = 0
        files.each do |file|
          failures.attempt(file.key) do
            blob = blobs[file.key]
            if blob.nil?
              uploads << [file.key, NOT_ON_SERVER]
            elsif same?(file, blob)
              up_to_date += 1
            else
              uploads << [file.key, DIFFERS]
              downloads << [file.key, DIFFERS]
            end
          end
        end

        # Blobs without a file in the listing: look where pull would write
        # them, so that whatever pull would skip or fail on is skipped or
        # fails here too.
        listed = files.to_set(&:key)
        lookup = Pull.new(@dir, @remote, out: @out, err: @err)
        blobs.values.sort_by(&:key).each do |blob|
          next if listed.include?(blob.key) || skipped.include?(blob.key)

          failures.attempt(blob.key) do
            file = lookup.local_file(blob.key)
            if file.nil?
              downloads << [blob.key, NOT_LOCAL]
            elsif file != :skipped # created since the directory was listed
              same?(file, blob) ? up_to_date += 1 : downloads << [blob.key, DIFFERS]
            end
          end
        end

        uploads.each { |key, reason| @out.puts "upload (#{reason}): #{key}" }
        downloads.sort.each { |key, reason| @out.puts "download (#{reason}): #{key}" }
        @out.puts summary(uploads.size, downloads.size, up_to_date) + failures.summary
        failures.check!
      end

      private

      def summary(uploads, downloads, up_to_date)
        if uploads.zero? && downloads.zero?
          "status: nothing to upload or download, #{up_to_date} up to date"
        else
          "status: #{uploads} to upload, #{downloads} to download, #{up_to_date} up to date"
        end
      end

      # The size is compared first only to skip hashing files that differ anyway.
      def same?(file, blob)
        blob.size == file.size && blob.sha256 == reading(file) { file.sha256 }
      end

      # Reports a local read error by key: the directory's own path may mean
      # nothing to the user (inside the client container it is a mount point).
      def reading(file)
        yield
      rescue SystemCallError => e
        raise Error, "cannot read #{file.key}: #{e.class.new.message}"
      end
    end
  end
end
