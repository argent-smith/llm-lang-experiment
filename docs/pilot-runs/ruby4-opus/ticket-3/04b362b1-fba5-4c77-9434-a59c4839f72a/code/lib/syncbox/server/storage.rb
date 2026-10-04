# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "time"

module Syncbox
  module Server
    # Blob store on top of the data directory. Blobs live under
    # <data_dir>/blobs/<key>; uploads are first written to <data_dir>/tmp and
    # then renamed into place, so readers never see a partially written blob.
    class Storage
      # The key cannot be used as a path inside the store: directory
      # traversal, an unrepresentable file name, or a clash with an existing
      # blob/directory on the way to it.
      class InvalidKey < StandardError; end

      CHUNK_SIZE = 64 * 1024
      # Linux limits on a path component and a whole path (including the NUL).
      NAME_MAX = 255
      PATH_MAX = 4096

      # Errors from creating the blob's parent directories or renaming the
      # upload into place that are caused by the key itself.
      KEY_ERRORS = [
        Errno::EEXIST, Errno::EISDIR, Errno::ENOTDIR, Errno::ENOTEMPTY,
        Errno::ENAMETOOLONG, Errno::EINVAL, Errno::EILSEQ
      ].freeze

      def initialize(data_dir)
        @blobs_dir = File.join(data_dir, "blobs")
        @tmp_dir = File.join(data_dir, "tmp")
      end

      # A valid key is a relative POSIX path of non-empty segments
      # other than "." and "..", each at most NAME_MAX bytes, in UTF-8 and
      # without NUL bytes.
      def self.valid_key?(key)
        return false if key.empty? || key.encoding != Encoding::UTF_8 || !key.valid_encoding? || key.include?("\0")

        key.split("/", -1).none? do |segment|
          segment.empty? || segment == "." || segment == ".." || segment.bytesize > NAME_MAX
        end
      end

      # Stores the contents of +input+ (an IO, or nil for an empty blob) under
      # +key+, replacing an existing blob. Returns {key:, sha256:, size:}.
      def put(key, input)
        raise InvalidKey unless self.class.valid_key?(key)

        path = File.join(@blobs_dir, key)
        # Checked up front: make_parents would otherwise leave behind the part of
        # the tree that still fits before failing.
        raise InvalidKey if path.bytesize >= PATH_MAX

        FileUtils.mkdir_p(@tmp_dir)
        tmp = File.join(@tmp_dir, SecureRandom.hex(16))
        digest, size = write_tmp(tmp, input)
        begin
          make_parents(File.dirname(path))
          File.rename(tmp, path)
        rescue Errno::ENOENT
          retry # a concurrent delete pruned a parent directory meanwhile
        rescue *KEY_ERRORS
          raise InvalidKey
        end
        { key: key, sha256: digest, size: size }
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      # Opens the blob stored under +key+ for reading, or returns nil if there
      # is none. The caller must close the returned File.
      def open(key)
        raise InvalidKey unless self.class.valid_key?(key)

        file = File.open(File.join(@blobs_dir, key), File::RDONLY | File::NOFOLLOW | File::BINARY)
        return file if file.stat.file?

        file.close
        nil
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::ENAMETOOLONG
        nil
      end

      # Removes the blob stored under +key+ together with the directories left
      # empty by it. Returns false if there is no such blob.
      def delete(key)
        raise InvalidKey unless self.class.valid_key?(key)

        path = File.join(@blobs_dir, key)
        return false unless File.lstat(path).file?

        File.unlink(path)
        prune_empty_parents(File.dirname(path))
        true
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::ENAMETOOLONG, Errno::EISDIR
        false
      end

      # Metadata of all blobs, sorted by key: [{key:, size:, sha256:, modified_at:}].
      def list
        blobs = []
        # Iterative walk: keys may nest thousands of directories deep.
        pending = [[@blobs_dir, nil]]
        until pending.empty?
          dir, prefix = pending.pop
          each_entry(dir) do |name|
            key = prefix ? "#{prefix}/#{name}" : name
            path = File.join(dir, name)
            stat = File.lstat(path)
            if stat.directory?
              pending << [path, key]
            elsif stat.file? && self.class.valid_key?(key) && (blob = metadata(key, path))
              blobs << blob
            end
          rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
            next # removed or replaced while listing
          end
        end
        blobs.sort_by { |blob| blob[:key] }
      end

      private

      def write_tmp(tmp, input)
        digest = Digest::SHA256.new
        size = 0
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::BINARY) do |file|
          buffer = +""
          while input&.read(CHUNK_SIZE, buffer)
            digest << buffer
            size += file.write(buffer)
          end
          file.fsync
        end
        [digest.hexdigest, size]
      end

      # Like FileUtils.mkdir_p, except that a directory pruned by a concurrent
      # delete right after another thread created it raises ENOENT (to be
      # retried) rather than EEXIST, which here means a clash with a blob.
      def make_parents(dir)
        missing = []
        until File.directory?(dir) || File.dirname(dir) == dir
          missing << dir
          dir = File.dirname(dir)
        end
        missing.reverse_each do |path|
          Dir.mkdir(path)
        rescue Errno::EEXIST
          raise unless File.stat(path).directory?
        end
      end

      # Without this, deleting docs/readme.txt would leave docs/ behind and a
      # later PUT of "docs" would clash with it.
      def prune_empty_parents(dir)
        while dir != @blobs_dir
          Dir.rmdir(dir)
          dir = File.dirname(dir)
        end
      rescue SystemCallError
        nil # not empty (or already gone): the rest of the chain stays
      end

      def each_entry(dir, &)
        Dir.each_child(dir, encoding: Encoding::UTF_8, &)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil # nothing stored yet, or removed (and maybe replaced by a blob) while listing
      end

      # Returns nil if +path+ is no longer a regular file: it may have been
      # replaced by a directory or a symlink since it was listed.
      def metadata(key, path)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::BINARY) do |file|
          stat = file.stat
          return nil unless stat.file?

          digest = Digest::SHA256.new
          buffer = +""
          digest << buffer while file.read(CHUNK_SIZE, buffer)
          { key: key, size: stat.size, sha256: digest.hexdigest, modified_at: stat.mtime.utc.iso8601(6) }
        end
      end
    end
  end
end
