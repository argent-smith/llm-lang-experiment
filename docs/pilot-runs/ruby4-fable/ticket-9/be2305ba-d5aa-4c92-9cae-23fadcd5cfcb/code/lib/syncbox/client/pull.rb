# frozen_string_literal: true

require "fileutils"
require "securerandom"

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
    # listing promised, so a target is either untouched or complete, never
    # half-written. Failures stop the pull at the first problem with a clear
    # message (continuing past per-file failures and reporting them is
    # ticket 11).
    class Pull
      class Error < StandardError; end

      STAGING_PREFIX = ".syncbox-tmp-"

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

        summary = Summary.new(listed: remote.size, downloaded: 0, unchanged: 0)
        remote.each do |blob|
          local = tree.lookup(blob.key)
          if local && local.sha256 == blob.sha256
            summary.unchanged += 1
            next
          end

          download(tree, blob, local)
          summary.downloaded += 1
        end

        @out.puts summary
        summary
      ensure
        @api.close
      end

      private

      def download(tree, blob, local)
        target = tree.path_for(blob.key)
        staging = nil
        begin
          FileUtils.mkdir_p(File.dirname(target))
          staging = File.join(File.dirname(target), "#{STAGING_PREFIX}#{SecureRandom.hex(8)}")
          result = @api.get(blob.key, staging)
          verify(blob, result)
          # Replacing a file keeps its permission bits (an executable stays
          # executable); a new file gets the default ones.
          File.chmod(local.mode, staging) if local&.mode
          File.rename(staging, target)
        rescue SystemCallError => e
          raise Error, "#{blob.key}: #{e.message}"
        ensure
          discard(staging) if staging
        end

        @out.puts "downloaded #{blob.key} (#{local ? 'changed' : 'new'}, #{result.size} bytes)"
      end

      def verify(blob, result)
        return if result.sha256 == blob.sha256

        raise Error, "#{blob.key}: downloaded sha256 #{result.sha256}, expected #{blob.sha256} from the listing " \
                     "(was the blob replaced on the server during the pull, or the transfer corrupted?)"
      end

      # Removes a staging file unless it has already been renamed into place.
      def discard(staging)
        File.unlink(staging)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        @err.puts "syncbox: warning: cannot remove staging file #{staging}: #{e.message}"
      end
    end
  end
end
