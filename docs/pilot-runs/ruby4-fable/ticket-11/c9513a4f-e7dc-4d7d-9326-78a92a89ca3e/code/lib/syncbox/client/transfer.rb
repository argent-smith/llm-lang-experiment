# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Syncbox
  module Client
    # The two transfers every command is made of, shared by push, pull and
    # sync: #upload streams a local file to the server with PUT /blobs/{key}
    # and checks the sha256 the server reports back; #download fetches a blob
    # with GET /blobs/{key} into a staging file next to its target and renames
    # it into place once the bytes received hash to what the listing promised,
    # so a local file is either untouched or complete, never half-written.
    # Both print one progress line to +out+.
    class Transfer
      class Error < Client::Error; end

      STAGING_PREFIX = ".syncbox-tmp-"

      def initialize(api:, out: $stdout, err: $stderr)
        @api = api
        @out = out
        @err = err
      end

      # Uploads +file+ (a LocalTree::LocalFile); +reason+ is shown in the
      # progress line. Returns the server's Api::PutResult.
      def upload(file, reason)
        result = begin
          @api.put(file.key, file.path)
        rescue SystemCallError => e
          # The file was readable when it was hashed; it has since vanished or
          # become unreadable. A local problem, reported as this file's.
          raise Error, "#{file.key}: cannot read #{file.path}: #{e.message}"
        end
        if result.sha256 != file.sha256
          raise Error, "#{file.key}: server stored sha256 #{result.sha256}, expected #{file.sha256} " \
                       "(was the file modified during the upload?)"
        end

        @out.puts "uploaded #{file.key} (#{reason}, #{file.size} bytes)"
        result
      end

      # Downloads +blob+ (an Api::RemoteBlob) to the path its key stands for
      # in +tree+, replacing +local+ (the LocalTree::LocalFile currently there,
      # or nil) while keeping its permission bits. Returns the Api::GetResult.
      def download(tree, blob, local, reason)
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

        @out.puts "downloaded #{blob.key} (#{reason}, #{result.size} bytes)"
        result
      end

      private

      def verify(blob, result)
        return if result.sha256 == blob.sha256

        raise Error, "#{blob.key}: downloaded sha256 #{result.sha256}, expected #{blob.sha256} from the listing " \
                     "(was the blob replaced on the server during the transfer, or the transfer corrupted?)"
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
