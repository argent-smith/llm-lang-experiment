# frozen_string_literal: true

module Syncbox
  module Client
    # `syncbox pull <dir>`: fetches the server's listing once and downloads
    # every blob that is missing locally or whose SHA-256 differs from the
    # local file's, writing it under <dir> at the path equal to its key
    # (missing directories are created). Files with identical content are
    # not downloaded again. Local files the server does not have are left
    # alone — the mirror image of push.
    #
    # Each blob is downloaded into a staging file next to its target and
    # renamed over it only after the bytes received hash to the sha256 the
    # listing promised (see Transfer), so a target is either untouched or
    # complete, never half-written.
    #
    # A blob that fails — its GET answers an unexpected status (a 404 for a
    # blob deleted since the listing, a 5xx), the request breaks, the bytes
    # do not hash to what the listing said, the file cannot be written, a
    # directory or symlink is in the way, the key is unsafe — does not stop
    # the pull: it is reported and the remaining blobs are still downloaded
    # (see Failures). The summary then counts the failures, the failed blobs
    # are listed on stderr and the Runner exits non-zero. What stops the pull
    # is a problem with the whole run: the directory is missing, the listing
    # cannot be fetched, or the server stops answering altogether
    # (Failures::ServerLost).
    class Pull
      # Raised when a download does not hash to what the listing promised or
      # cannot be put in place.
      Error = Transfer::Error

      STAGING_PREFIX = Transfer::STAGING_PREFIX

      Summary = Struct.new(:listed, :downloaded, :unchanged, :failed, keyword_init: true) do
        def to_s
          counts = ["#{downloaded} downloaded", "#{unchanged} unchanged"]
          counts << "#{failed} failed" if failed.positive?
          "pull done: #{counts.join(', ')}, #{listed} blob(s) listed"
        end
      end

      def initialize(dir:, api:, out: $stdout, err: $stderr)
        @dir = dir
        @api = api
        @out = out
        @err = err
      end

      def call
        tree = LocalTree.new(@dir)
        tree.require_directory!
        remote = @api.list
        transfer = Transfer.new(api: @api, out: @out, err: @err)
        failures = Failures.new(err: @err)

        summary = Summary.new(listed: remote.size, downloaded: 0, unchanged: 0, failed: 0)
        begin
          remote.each_with_index do |blob, index|
            failures.attempt(blob.key, remaining: remote.size - index - 1) do
              local = tree.lookup(blob.key)
              if local && local.sha256 == blob.sha256
                summary.unchanged += 1
              else
                transfer.download(tree, blob, local, local ? "changed" : "new")
                summary.downloaded += 1
              end
            end
          end
        rescue Failures::ServerLost => e
          failures.report("pull", total: remote.size, not_attempted: e.not_attempted)
          raise
        end

        summary.failed = failures.size
        @out.puts summary
        failures.report("pull", total: remote.size)
        summary
      ensure
        @api.close
      end
    end
  end
end
