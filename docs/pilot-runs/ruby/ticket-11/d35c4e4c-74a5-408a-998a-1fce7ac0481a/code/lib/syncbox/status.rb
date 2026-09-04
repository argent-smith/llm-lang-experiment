require "digest"
require_relative "local_files"
require_relative "failure"

module Syncbox
  # Implements `syncbox status`: a strictly read-only dry run. Compares a
  # local directory against the server's blob listing (GET /blobs only —
  # no PUT/DELETE, no GET /blobs/{key}, no local writes) and reports what
  # `push` would upload and what `pull` would download, using exactly
  # push's and pull's own comparison criteria independently. A file that
  # diverged on both sides therefore shows up in both directions; picking
  # a winner is sync's conflict-resolution rule (SYNCBOX-SPEC.md), out of
  # scope here.
  #
  # Status makes no per-file server request, so the only per-file failure
  # mode is a local file that can't be read to compute its SHA-256. Per
  # SYNCBOX-SPEC.md's partial-failure rule, that doesn't abort the rest of
  # the comparison -- the unreadable key is excluded from the three normal
  # buckets and reported separately via Result#failed.
  class Status
    Result = Struct.new(:to_upload, :to_download, :unchanged, :failed, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
    end

    def call
      remote_shas = @client.list_blobs

      local_shas = {}
      failed = []
      LocalFiles.list(@dir).each do |key, path|
        local_shas[key] = Digest::SHA256.file(path).hexdigest
      rescue SystemCallError, IOError => e
        failed << Failure.new(key: key, message: "local file error: #{e.message}")
      end
      failed_keys = failed.map(&:key)

      to_upload = local_shas.reject { |key, sha256| remote_shas[key] == sha256 }.keys
      to_download = remote_shas.reject { |key, sha256| local_shas[key] == sha256 || failed_keys.include?(key) }.keys
      unchanged = local_shas.keys.select { |key| local_shas[key] == remote_shas[key] }

      Result.new(to_upload: to_upload.sort, to_download: to_download.sort, unchanged: unchanged.sort,
                 failed: failed.sort_by(&:key))
    end
  end
end
