require "digest"
require_relative "local_files"

module Syncbox
  # Implements `syncbox status`: a strictly read-only dry run. Compares a
  # local directory against the server's blob listing (GET /blobs only —
  # no PUT/DELETE, no GET /blobs/{key}, no local writes) and reports what
  # `push` would upload and what `pull` would download, using exactly
  # push's and pull's own comparison criteria independently. A file that
  # diverged on both sides therefore shows up in both directions; picking
  # a winner is sync's conflict-resolution rule (SYNCBOX-SPEC.md), out of
  # scope here.
  class Status
    Result = Struct.new(:to_upload, :to_download, :unchanged, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
    end

    def call
      remote_shas = @client.list_blobs
      local_shas = LocalFiles.list(@dir).transform_values { |path| Digest::SHA256.file(path).hexdigest }

      to_upload = local_shas.reject { |key, sha256| remote_shas[key] == sha256 }.keys
      to_download = remote_shas.reject { |key, sha256| local_shas[key] == sha256 }.keys
      unchanged = local_shas.keys.select { |key| local_shas[key] == remote_shas[key] }

      Result.new(to_upload: to_upload.sort, to_download: to_download.sort, unchanged: unchanged.sort)
    end
  end
end
