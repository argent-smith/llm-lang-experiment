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
    # rename(2) replaces the target atomically: a reader that opened the old
    # file keeps reading it, one that opens afterwards gets the new one, and of
    # concurrent puts to one key the last rename wins whole.
    class Store
      CHUNK_SIZE = 64 * 1024
      STAGING_SUFFIX = ".part"
      # Linux limits on a file name and a whole path (including its NUL).
      NAME_MAX = 255
      PATH_MAX = 4096
      # How many times put recreates parent directories removed under it.
      PUT_ATTEMPTS = 100

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
        @blobs_dir = File.expand_path(File.join(data_dir, "blobs")).b
        @tmp_dir = File.join(data_dir, "tmp").b
      end

      # Readies the data dir before serving: creates the store's directories,
      # removes staging files left by a server killed mid-upload, and checks
      # that staged files can be renamed into the blobs dir. rename(2) fails
      # with EXDEV rather than copying when the two are on different
      # filesystems or mounts; this reports that up front instead of failing
      # every put. Assumes it is the only server using the data dir.
      def prepare!
        FileUtils.mkdir_p(@tmp_dir)
        FileUtils.mkdir_p(@blobs_dir)
        Dir.children(@tmp_dir, encoding: Encoding::BINARY).each do |name|
          FileUtils.rm_f(File.join(@tmp_dir, name)) if name.end_with?(STAGING_SUFFIX)
        end
        check_rename_into_store
      end

      # Stores the contents of io (nil means empty) under key, replacing any
      # existing blob. Returns {key:, sha256:, size:}.
      def put(key, io)
        key = self.class.validate_key(key)
        path = blob_path(key)
        # Checked up front: the kernel would only report this halfway through
        # creating the parent directories, leaving a partial chain behind.
        if path.bytesize >= PATH_MAX || key.split("/").any? { |s| s.bytesize > NAME_MAX }
          raise InvalidKeyError, "key is too long for the filesystem"
        end

        FileUtils.mkdir_p(@tmp_dir)
        FileUtils.mkdir_p(@blobs_dir)
        tmp = staging_path
        sha256, size = write_file(tmp, io)

        attempts = 0
        begin
          make_parent_dirs(key)
          raise InvalidKeyError, "key resolves outside the store" unless confined_on_disk?(path)

          File.rename(tmp, path)
        rescue Errno::ENOENT
          # A concurrent delete pruned a parent directory right after it was
          # created; create it again.
          retry if (attempts += 1) < PUT_ATTEMPTS
          raise
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
        path = blob_path(self.class.validate_key(key))
        return nil unless confined_on_disk?(path)

        file = File.open(path, File::RDONLY | File::NOFOLLOW | File::BINARY)
        # Directories open fine on Linux; only regular files are blobs.
        return file if file.stat.file?

        file.close
        nil
      rescue Errno::ENOENT, Errno::ELOOP, *KEY_PATH_ERRORS
        nil
      end

      # Removes the blob stored under key; returns false if there is none.
      # As in the listing, only regular files reached through real directories
      # are blobs, so symlinks are neither followed nor removed. Directories
      # left empty are pruned so their paths can be used as keys again.
      def delete(key)
        path = blob_path(self.class.validate_key(key))
        return false unless blob_file?(path)

        begin
          File.unlink(path)
        rescue Errno::ENOENT
          return false # deleted concurrently
        end
        prune_empty_dirs(File.dirname(path))
        true
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

      def staging_path
        File.join(@tmp_dir, "#{SecureRandom.hex(16)}#{STAGING_SUFFIX}")
      end

      # Renames a staged file into the blobs dir and removes it again. The
      # probe's name is not valid UTF-8, so even if the process dies before
      # removing it, it is never listed and no key can name it.
      def check_rename_into_store
        tmp = staging_path
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600, &:close)
        probe = File.join(@blobs_dir, ".rename-probe-#{SecureRandom.hex(8)}-\xFF".b)
        File.rename(tmp, probe)
      ensure
        FileUtils.rm_f(tmp) if tmp
        FileUtils.rm_f(probe) if probe
      end

      # The on-disk path of a validated key. Besides the segment checks in
      # validate_key, the normalized path must lie strictly inside the blobs
      # dir, so no spelling of a key can name the dir itself or leave it.
      def blob_path(key)
        # Joined first: expand_path must never get the key as its own argument,
        # where a leading "~" would be expanded to a home directory.
        path = File.expand_path(File.join(@blobs_dir, key.b)).b
        raise InvalidKeyError, "key resolves outside the store" unless path.start_with?("#{@blobs_dir}/")

        path
      end

      # Whether path stays inside the blobs dir once symlinks are resolved:
      # the deepest existing directory above it must resolve to itself, i.e.
      # no symlink (not even one pointing back inside) sits between the blobs
      # dir and the blob. Parts that don't exist yet can't redirect anywhere.
      def confined_on_disk?(path)
        dir = File.dirname(path)
        loop do
          dir = File.dirname(dir) until dir == @blobs_dir || entry_exists?(dir)
          begin
            return File.realpath(dir).b == File.realpath(@blobs_dir).b + dir.byteslice(@blobs_dir.bytesize..)
          rescue Errno::ENOENT
            return false if dir == @blobs_dir

            # A concurrent delete pruned the directory meanwhile; look further up.
          end
        end
      rescue SystemCallError
        false
      end

      # Like File.exist?, but true for a symlink whatever it points at.
      def entry_exists?(path)
        File.lstat(path)
        true
      rescue Errno::ENOENT
        false
      end

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

      # Creates the directories above key's blob. Unlike FileUtils.mkdir_p this
      # tells a non-directory in the way (EEXIST: the key can't be stored)
      # from a directory that another put created and a concurrent delete
      # pruned right away (ENOENT: put retries).
      def make_parent_dirs(key)
        dir = @blobs_dir
        key.b.split("/")[0...-1].each do |segment|
          dir = File.join(dir, segment)
          begin
            Dir.mkdir(dir)
          rescue Errno::EEXIST
            # lstat raises ENOENT if the entry is gone again; if it was
            # recreated meanwhile it is a directory and all is well. A symlink
            # is never descended into, even if it points at a directory.
            raise unless File.lstat(dir).directory?
          end
        end
      end

      # Whether path is a regular file (not a symlink to one) reached without
      # passing through a symlink.
      def blob_file?(path)
        confined_on_disk?(path) && File.lstat(path).file?
      rescue Errno::ENOENT, Errno::ELOOP, *KEY_PATH_ERRORS
        false
      end

      # Removes dir and its parents up to (not including) the blobs dir for as
      # long as they are empty.
      def prune_empty_dirs(dir)
        while dir.bytesize > @blobs_dir.bytesize
          Dir.rmdir(dir)
          dir = File.dirname(dir)
        end
      rescue SystemCallError
        # Not empty (or already gone): the remaining parents are in use.
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
