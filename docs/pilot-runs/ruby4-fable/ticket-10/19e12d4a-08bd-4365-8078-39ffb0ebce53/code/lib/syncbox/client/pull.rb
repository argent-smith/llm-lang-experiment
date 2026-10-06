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
    # complete, never half-written. Failures stop the pull at the first
    # problem with a clear message (continuing past per-file failures and
    # reporting them is ticket 11).
    class Pull
      # Raised when a download does not hash to what the listing promised or
      # cannot be put in place.
      Error = Transfer::Error

      STAGING_PREFIX = Transfer::STAGING_PREFIX

      Summary = Struct.new(:listed, :downloaded, :unchanged, keyword_init: true) do
        def to_s
          "pull done: #{downloaded} downloaded, #{unchanged} unchanged, #{listed} blob(s) listed"
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

        summary = Summary.new(listed: remote.size, downloaded: 0, unchanged: 0)
        remote.each do |blob|
          local = tree.lookup(blob.key)
          if local && local.sha256 == blob.sha256
            summary.unchanged += 1
            next
          end

          transfer.download(tree, blob, local, local ? "changed" : "new")
          summary.downloaded += 1
        end

        @out.puts summary
        summary
      ensure
        @api.close
      end
    end
  end
end
