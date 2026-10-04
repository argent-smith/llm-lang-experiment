# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "time"

module Syncbox
  module Server
    # Raised for a key that cannot name a blob on this server.
    class InvalidKeyError < StandardError; end

    # Blobs stored as regular files under <data_dir>/blobs/<key>. Uploads are
    # staged in <data_dir>/tmp and renamed into place, so a blob is never
    # visible half-written and staging files can never collide with a key.
    class Store
      CHUNK_SIZE = 64 * 1024
      # Linux limits on a file name and a whole path (including its NUL).
      NAME_MAX = 255
      PATH_MAX = 4096

      # Errors from creating the blob's path that mean the key cannot be
      # represented here: a component is too long, or a file is in the way of
      # a directory (or the other way round).
      KEY_PATH_ERRORS = [
        Errno::ENAMETOOLONG, Errno::ENOTDIR, Errno::EISDIR, Errno::EEXIST,
        Errno::EILSEQ, Errno::EINVAL
      ].freeze

      # Checks a decoded key and returns it as a UTF-8 string. A key is a
      # relative POSIX path: no empty, "." or ".." segments, so it can't
      # escape the store or alias another key.
      def self.validate_key(key)
        key = key.b.force_encoding(Encoding::UTF_8)
        raise InvalidKeyError, "key is not valid UTF-8" unless key.valid_encoding?
        raise InvalidKeyError, "key contains a NUL byte" if key.include?("\0")

        segments = key.split("/", -1)
        if segments.empty? || segments.any? { |s| s.empty? || s == "." || s == ".." }
          raise InvalidKeyError, "key must be a relative path without empty, '.' or '..' segments"
        end

        key
      end

      def initialize(data_dir)
        # Paths are handled as raw bytes so that joining never hits an
        # encoding mismatch between the data dir and keys or file names.
        @blobs_dir = File.join(data_dir, "blobs").b
        @tmp_dir = File.join(data_dir, "tmp").b
      end

      # Stores the contents of io (nil means empty) under key, replacing any
      # existing blob. Returns {key:, sha256:, size:}.
      def put(key, io)
        key = self.class.validate_key(key)
        path = File.join(@blobs_dir, key.b)
        # Checked up front: the kernel would only report this halfway through
        # creating the parent directories, leaving a partial chain behind.
        if path.bytesize >= PATH_MAX || key.split("/").any? { |s| s.bytesize > NAME_MAX }
          raise InvalidKeyError, "key is too long for the filesystem"
        end

        FileUtils.mkdir_p(@tmp_dir)
        tmp = File.join(@tmp_dir, "#{SecureRandom.hex(16)}.part")
        sha256, size = write_file(tmp, io)

        begin
          FileUtils.mkdir_p(File.dirname(path))
          File.rename(tmp, path)
        rescue *KEY_PATH_ERRORS => e
          raise InvalidKeyError, "key cannot be stored as a file (#{e.class.name.split('::').last})"
        end

        { key: key, sha256: sha256, size: size }
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      # Opens the blob stored under key for reading, or returns nil if there
      # is none. The caller must close the returned File. The open handle
      # keeps serving the old contents if the blob is replaced meanwhile.
      def open(key)
        key = self.class.validate_key(key)
        file = File.open(File.join(@blobs_dir, key.b), File::RDONLY | File::NOFOLLOW | File::BINARY)
        # Directories open fine on Linux; only regular files are blobs.
        return file if file.stat.file?

        file.close
        nil
      rescue Errno::ENOENT, Errno::ELOOP, *KEY_PATH_ERRORS
        nil
      end

      # Metadata of every blob, sorted by key. Entries that are not regular
      # files, have names that aren't valid UTF-8, or vanish or become
      # unreadable while listing are skipped rather than failing the listing.
      def list
        entries = []
        # Iterative walk: keys may nest thousands of directories deep, more
        # than a request thread's stack would allow with recursion.
        pending = [[@blobs_dir, nil]]
        until pending.empty?
          dir, prefix = pending.pop
          each_entry(dir, prefix) do |path, key, stat|
            if stat.directory?
              pending << [path, key]
            elsif stat.file?
              entries << blob_meta(path, key)
            end
          end
        end
        entries.compact.sort_by { |e| e[:key] }
      end

      private

      def write_file(path, io)
        digest = Digest::SHA256.new
        size = 0
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) do |f|
          buf = String.new(capacity: CHUNK_SIZE)
          while io&.read(CHUNK_SIZE, buf)
            digest << buf
            size += buf.bytesize
            f.write(buf)
          end
          f.flush
          f.fsync
        end
        [digest.hexdigest, size]
      end

      # Yields path, key and lstat of each entry of dir with a UTF-8 name.
      def each_entry(dir, prefix)
        Dir.children(dir, encoding: Encoding::BINARY).each do |raw_name|
          name = raw_name.dup.force_encoding(Encoding::UTF_8)
          next unless name.valid_encoding?

          path = File.join(dir, raw_name)
          begin
            stat = File.lstat(path)
          rescue SystemCallError
            next
          end
          yield path, prefix ? "#{prefix}/#{name}" : name, stat
        end
      rescue SystemCallError
        # Directory missing (nothing stored yet), replaced or unreadable.
      end

      # Size, mtime and hash all come from one open handle, so they describe
      # the same version even if the blob is replaced while it is being read.
      def blob_meta(path, key)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::BINARY) do |f|
          stat = f.stat
          return nil unless stat.file?

          digest = Digest::SHA256.new
          buf = String.new(capacity: CHUNK_SIZE)
          digest << buf while f.read(CHUNK_SIZE, buf)
          { key: key, size: stat.size, sha256: digest.hexdigest, modified_at: stat.mtime.utc.iso8601(6) }
        end
      rescue SystemCallError
        nil
      end
    end
  end
end
