require "digest"
require "find"
require "pathname"

module Syncbox
  # Implements `syncbox push`: walks a local directory, compares each
  # file's SHA-256 against the server's listing, and uploads whatever is
  # missing or different. Never deletes anything server-side — push is
  # one-directional, upload-only, per SYNCBOX-SPEC.md.
  class Push
    Result = Struct.new(:uploaded, :skipped, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
    end

    def call
      remote_shas = @client.list_blobs

      uploaded = []
      skipped = []

      local_files.each do |key, path|
        if remote_shas[key] == Digest::SHA256.file(path).hexdigest
          skipped << key
        else
          @client.put_blob(key, File.binread(path))
          uploaded << key
        end
      end

      Result.new(uploaded: uploaded.sort, skipped: skipped.sort)
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
  end
end
