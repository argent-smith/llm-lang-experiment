# frozen_string_literal: true

require "digest"
require "find"

module Syncbox
  module Client
    # Recursive scan of a local directory: every regular file becomes a
    # LocalFile whose key is its POSIX path relative to the directory (the
    # same convention the server uses) and whose sha256 is the hex digest of
    # its contents.
    #
    # Symlinks (to files or directories) and special files (sockets, FIFOs,
    # devices) cannot be represented as blobs and are skipped with a warning
    # — symlinks are never followed, so a link cannot drag anything from
    # outside the directory into the upload or create a cycle. Hidden entries
    # are ordinary files and are included. A name that is not valid UTF-8
    # cannot be a key (the server rejects it) and raises Error.
    class LocalTree
      class Error < StandardError; end

      CHUNK_SIZE = 64 * 1024

      LocalFile = Struct.new(:key, :path, :size, :sha256, keyword_init: true)

      # Yields a warning message for every skipped entry; returns the files
      # sorted by key.
      def self.scan(dir, &on_warning)
        new(dir).scan(&on_warning)
      end

      attr_reader :root

      def initialize(dir)
        @root = File.expand_path(dir)
      end

      def scan
        raise Error, "not a directory: #{@root}" unless File.directory?(@root)

        files = []
        Find.find(@root) do |path|
          next if path == @root

          key = key_for(path)
          stat = File.lstat(path)
          if stat.symlink?
            yield "skipping #{key}: symbolic links are not uploaded" if block_given?
          elsif stat.directory?
            next
          elsif stat.file?
            files << file_entry(key, path)
          elsif block_given?
            yield "skipping #{key}: not a regular file (#{stat.ftype})"
          end
        end
        files.sort_by!(&:key)
      rescue SystemCallError => e
        raise Error, "cannot read #{@root}: #{e.message}"
      end

      private

      def key_for(path)
        key = path.byteslice((@root.bytesize + 1)..).dup.force_encoding(Encoding::UTF_8)
        raise Error, "file name is not valid UTF-8 and cannot be a key: #{key.inspect}" unless key.valid_encoding?

        key
      end

      def file_entry(key, path)
        digest = Digest::SHA256.new
        size = 0
        File.open(path, "rb") do |file|
          while (chunk = file.read(CHUNK_SIZE))
            digest << chunk
            size += chunk.bytesize
          end
        end
        LocalFile.new(key: key, path: path, size: size, sha256: digest.hexdigest)
      rescue SystemCallError => e
        raise Error, "cannot read #{key}: #{e.message}"
      end
    end
  end
end
