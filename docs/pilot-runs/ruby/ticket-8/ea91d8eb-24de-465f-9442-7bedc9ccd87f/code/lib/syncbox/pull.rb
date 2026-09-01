require "digest"
require "find"
require "pathname"
require "fileutils"

module Syncbox
  # Implements `syncbox pull`: the mirror image of Push. Compares the
  # server's blob listing against the local directory and downloads
  # whatever is missing or different by SHA-256. Never deletes local
  # files absent from the server — pull is one-directional, download-only,
  # per SYNCBOX-SPEC.md.
  class Pull
    Result = Struct.new(:downloaded, :skipped, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
    end

    def call
      remote_shas = @client.list_blobs
      local_shas = local_files.transform_values { |path| Digest::SHA256.file(path).hexdigest }

      downloaded = []
      skipped = []

      remote_shas.each do |key, sha256|
        if local_shas[key] == sha256
          skipped << key
        else
          write_blob(key, @client.get_blob(key))
          downloaded << key
        end
      end

      Result.new(downloaded: downloaded.sort, skipped: skipped.sort)
    end

    private

    # { key => absolute path }, one entry per regular file under @dir,
    # keyed by its POSIX path relative to @dir — the same convention the
    # server uses for GET /blobs.
    def local_files
      root = Pathname.new(File.expand_path(@dir))
      files = {}

      Find.find(root.to_s) do |path|
        next unless File.file?(path)

        key = Pathname.new(path).relative_path_from(root).to_s
        files[key] = path
      end

      files
    end

    def write_blob(key, body)
      path = File.join(File.expand_path(@dir), key)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
  end
end
