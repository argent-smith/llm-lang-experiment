require "digest"
require_relative "local_files"
require_relative "client"
require_relative "failure"

module Syncbox
  # Implements `syncbox push`: walks a local directory, compares each
  # file's SHA-256 against the server's listing, and uploads whatever is
  # missing or different. Never deletes anything server-side — push is
  # one-directional, upload-only, per SYNCBOX-SPEC.md.
  #
  # A single file failing (unreadable locally, a network error on its
  # request, a 5xx from the server) doesn't abort the rest -- per
  # SYNCBOX-SPEC.md's partial-failure rule, every other file is still
  # attempted and the failure is collected into Result#failed for the
  # caller to report.
  class Push
    Result = Struct.new(:uploaded, :skipped, :failed, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
    end

    def call
      remote_shas = @client.list_blobs

      uploaded = []
      skipped = []
      failed = []

      LocalFiles.list(@dir).each do |key, path|
        if remote_shas[key] == Digest::SHA256.file(path).hexdigest
          skipped << key
        else
          @client.put_blob(key, File.binread(path))
          uploaded << key
        end
      rescue Client::ConnectionError, Client::ServerError => e
        failed << Failure.new(key: key, message: e.message)
      rescue SystemCallError, IOError => e
        failed << Failure.new(key: key, message: "local file error: #{e.message}")
      end

      Result.new(uploaded: uploaded.sort, skipped: skipped.sort, failed: failed.sort_by(&:key))
    end
  end
end
