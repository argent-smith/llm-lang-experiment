# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox push: uploads the files of a local directory that the server
    # lacks or stores with different content. Files identical to the stored
    # blob (by SHA-256) are not sent again; blobs without a local file are
    # left alone.
    class Push
      def initialize(dir, remote, out:, err:)
        @dir = dir
        @remote = remote
        @out = out
        @err = err
      end

      def run
        raise Error, "not a directory: #{@dir}" unless File.directory?(@dir)

        files = LocalTree.new(@dir).files { |key, reason| @err.puts "syncbox: skipping #{key}: #{reason}" }
        stored = @remote.list
        changed = files.reject { |file| up_to_date?(file, stored[file.key]) }
        changed.each do |file|
          reading(file) { file.open { |io| @remote.put(file.key, io) } }
          @out.puts "uploaded #{file.key}"
        end
        @out.puts "push: #{changed.size} uploaded, #{files.size - changed.size} up to date"
      end

      private

      # The size is compared first only to skip hashing files that differ anyway.
      def up_to_date?(file, blob)
        blob && blob.size == file.size && blob.sha256 == reading(file) { file.sha256 }
      end

      # Reports a local read error by key: the directory's own path may mean
      # nothing to the user (inside the client container it is a mount point).
      def reading(file)
        yield
      rescue SystemCallError => e
        raise Error, "cannot read #{file.key}: #{e.class.new.message}"
      end
    end
  end
end
