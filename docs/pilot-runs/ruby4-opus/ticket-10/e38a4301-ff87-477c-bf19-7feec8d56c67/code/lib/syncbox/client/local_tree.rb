# frozen_string_literal: true

require "digest"

module Syncbox
  module Client
    # The regular files under a local directory, keyed the way the server
    # keys blobs: by their relative POSIX path ("docs/readme.txt").
    #
    # Symlinks and special files (FIFOs, sockets, devices) are not synced:
    # they are reported to the caller and skipped. Following symlinks could
    # loop or leave the directory, and reading a FIFO could block forever.
    # The client's own state directory (Client::STATE_DIR) is left out silently.
    class LocalTree
      CHUNK_SIZE = 64 * 1024

      # A regular file found under the directory.
      LocalFile = Data.define(:key, :path, :size) do
        # Opened without following symlinks: the entry was a regular file
        # when listed and must not be swapped for a link to elsewhere.
        def open(&)
          File.open(path, File::RDONLY | File::NOFOLLOW, binmode: true, &)
        end

        def sha256
          open do |file|
            digest = Digest::SHA256.new
            buffer = +""
            digest << buffer while file.read(CHUNK_SIZE, buffer)
            digest.hexdigest
          end
        end
      end

      def initialize(root)
        @root = root
      end

      # Returns the files sorted by key. Calls the block with the key and a
      # reason for every entry that is skipped. Raises Error if a file name
      # cannot be a key or a directory cannot be read.
      def files
        files = []
        # Iterative walk: directories may nest thousands of levels deep.
        pending = [[@root, nil]]
        until pending.empty?
          dir, prefix = pending.pop
          children(dir, prefix).each do |name|
            key = prefix ? "#{prefix}/#{name}" : name
            next if Client.reserved_key?(key)
            path = File.join(dir, name)
            stat = File.lstat(path)
            if stat.directory?
              pending << [path, key]
            elsif stat.file?
              files << LocalFile.new(key: key, path: path, size: stat.size)
            elsif block_given?
              yield key, stat.symlink? ? "symbolic link" : "not a regular file"
            end
          rescue Errno::ENOENT
            next # removed while listing
          end
        end
        files.sort_by(&:key)
      end

      private

      def children(dir, prefix)
        names = Dir.children(dir, encoding: Encoding::UTF_8)
        invalid = names.find { |name| !name.valid_encoding? }
        if invalid
          raise Error, "file name is not valid UTF-8 and cannot be a key: #{display(prefix, invalid.b.inspect)}"
        end

        names
      rescue Errno::ENOENT
        [] # removed while listing
      rescue SystemCallError => e
        raise Error, "cannot read directory #{display(prefix, nil)}: #{e.class.new.message}"
      end

      def display(prefix, name)
        [prefix, name].compact.join("/").then { |path| path.empty? ? @root : path }
      end
    end
  end
end
