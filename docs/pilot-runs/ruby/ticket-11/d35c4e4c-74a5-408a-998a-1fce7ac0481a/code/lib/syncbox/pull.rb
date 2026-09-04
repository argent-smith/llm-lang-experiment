require "digest"
require "fileutils"
require_relative "local_files"
require_relative "client"
require_relative "failure"

module Syncbox
  # Implements `syncbox pull`: the mirror image of Push. Compares the
  # server's blob listing against the local directory and downloads
  # whatever is missing or different by SHA-256. Never deletes local
  # files absent from the server — pull is one-directional, download-only,
  # per SYNCBOX-SPEC.md.
  #
  # A single key failing (a network error or 5xx on its GET, a local write
  # error) doesn't abort the rest -- per SYNCBOX-SPEC.md's partial-failure
  # rule, every other key is still attempted and the failure is collected
  # into Result#failed for the caller to report.
  class Pull
    Result = Struct.new(:downloaded, :skipped, :failed, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
    end

    def call
      remote_shas = @client.list_blobs
      local_paths = LocalFiles.list(@dir)

      downloaded = []
      skipped = []
      failed = []

      remote_shas.each do |key, sha256|
        local_path = local_paths[key]
        local_sha = local_path && Digest::SHA256.file(local_path).hexdigest

        if local_sha == sha256
          skipped << key
        else
          write_blob(key, @client.get_blob(key))
          downloaded << key
        end
      rescue Client::ConnectionError, Client::ServerError => e
        failed << Failure.new(key: key, message: e.message)
      rescue SystemCallError, IOError => e
        failed << Failure.new(key: key, message: "local file error: #{e.message}")
      end

      Result.new(downloaded: downloaded.sort, skipped: skipped.sort, failed: failed.sort_by(&:key))
    end

    private

    def write_blob(key, body)
      path = File.join(File.expand_path(@dir), key)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
  end
end
