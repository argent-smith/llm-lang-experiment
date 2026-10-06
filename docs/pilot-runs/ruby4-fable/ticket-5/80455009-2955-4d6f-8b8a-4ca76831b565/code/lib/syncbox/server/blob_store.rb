# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "time"

module Syncbox
  module Server
    # On-disk blob storage underneath the configured data dir:
    #
    #   <data_dir>/blobs/<key>   blob contents, one file per key
    #   <data_dir>/tmp/          staging area for atomic writes
    #
    # Writes go to a temp file first and are then rename(2)d into place, so a
    # reader never observes a half-written blob and concurrent PUTs for
    # different keys cannot corrupt each other.
    #
    # Directories under <data_dir>/blobs/ exist only as long as they hold a
    # blob: #put creates them on demand and #delete removes the ones it leaves
    # empty, so a key whose last blob was deleted behaves exactly like a key
    # that never existed (in particular, it can be reused as a file name).
    #
    # A key is a POSIX path relative to the storage root. Every public method
    # takes the *decoded* key; #validate_key maps anything that cannot be a
    # safe file name (traversal, absolute path, empty segment, NUL, invalid
    # UTF-8, over-long segment) to InvalidKey.
    class BlobStore
      class Error < StandardError; end
      class InvalidKey < Error; end
      class NotFound < Error; end

      MAX_SEGMENT_BYTES = 255
      CHUNK_SIZE = 64 * 1024
      RENAME_RETRIES = 3

      # Filesystem errors that mean "this key cannot be materialised here"
      # (e.g. a parent segment is an existing file, or the key is a directory)
      # rather than a server fault.
      UNREPRESENTABLE_KEY_ERRORS = [
        Errno::ENOTDIR, Errno::EISDIR, Errno::EEXIST, Errno::ENAMETOOLONG,
        Errno::EINVAL, Errno::ELOOP, Errno::EPERM
      ].freeze

      Meta = Struct.new(:key, :size, :sha256, :modified_at, keyword_init: true) do
        def to_h
          { key: key, size: size, sha256: sha256, modified_at: modified_at }
        end
      end

      attr_reader :root

      def initialize(data_dir)
        @root = File.join(File.expand_path(data_dir), "blobs")
        @tmp_dir = File.join(File.expand_path(data_dir), "tmp")
      end

      # Raises InvalidKey unless +key+ is a safe relative path; returns +key+.
      def validate_key(key)
        raise InvalidKey, "key must not be empty" if key.nil? || key.empty?
        raise InvalidKey, "key must not contain NUL" if key.include?("\0")

        key = key.dup.force_encoding(Encoding::UTF_8)
        raise InvalidKey, "key is not valid UTF-8" unless key.valid_encoding?
        raise InvalidKey, "key must be relative" if key.start_with?("/")

        key.split("/", -1).each do |segment|
          raise InvalidKey, "key must not contain empty segments" if segment.empty?
          raise InvalidKey, "key must not contain . or .. segments" if [".", ".."].include?(segment)
          raise InvalidKey, "key segment too long" if segment.bytesize > MAX_SEGMENT_BYTES
        end

        key
      end

      # Streams +io+ (anything responding to #read(len)) into the blob for
      # +key+, replacing any previous contents. Returns a Meta.
      def put(key, io)
        key = validate_key(key)
        path = path_for(key)

        FileUtils.mkdir_p(@tmp_dir)
        tmp = File.join(@tmp_dir, "put-#{SecureRandom.hex(16)}")
        digest = Digest::SHA256.new
        size = 0

        begin
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o644, binmode: true) do |out|
            if io
              while (chunk = io.read(CHUNK_SIZE))
                break if chunk.empty?

                out.write(chunk)
                digest << chunk
                size += chunk.bytesize
              end
            end
            out.flush
            out.fsync
          end

          move_into_place(tmp, path)
        rescue *UNREPRESENTABLE_KEY_ERRORS => e
          raise InvalidKey, "key cannot be stored as a file: #{e.message}"
        ensure
          File.unlink(tmp) if File.exist?(tmp)
        end

        Meta.new(key: key, size: size, sha256: digest.hexdigest, modified_at: mtime_of(path))
      end

      # Opens the blob for reading and yields [File, size]. Raises InvalidKey
      # for unsafe keys and NotFound for missing keys or keys that are not
      # regular files.
      def open(key)
        path = existing_file_path(key)
        File.open(path, "rb") do |file|
          yield file, file.size
        end
      rescue Errno::ENOENT, *UNREPRESENTABLE_KEY_ERRORS
        raise NotFound, "blob not found: #{key}"
      end

      # Removes the blob for +key+ together with any parent directories that
      # become empty as a result (the storage root itself is kept). Raises
      # InvalidKey for unsafe keys and NotFound when there is no blob — a
      # directory or a dangling symlink at the key's path is not a blob.
      def delete(key)
        path = existing_file_path(key)
        begin
          File.unlink(path)
        rescue Errno::ENOENT, *UNREPRESENTABLE_KEY_ERRORS
          raise NotFound, "blob not found: #{key}"
        end
        prune_empty_parents(path)
        nil
      end

      # All stored blobs with metadata, sorted by key.
      def list
        return [] unless File.directory?(@root)

        entries = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).filter_map do |rel|
          rel = rel.dup.force_encoding(Encoding::UTF_8)
          next unless rel.valid_encoding?
          next if rel.split("/").include?(".")

          path = File.join(@root, rel)
          begin
            next unless File.file?(path)

            Meta.new(key: rel, size: File.size(path), sha256: sha256_of(path), modified_at: mtime_of(path))
          rescue Errno::ENOENT, *UNREPRESENTABLE_KEY_ERRORS
            nil # vanished or changed shape between glob and stat; skip
          end
        end
        entries.sort_by(&:key)
      end

      private

      def path_for(key)
        path = File.join(@root, key)
        # Belt and braces: validate_key already rules out traversal, but never
        # hand out a path that escapes the storage root.
        unless File.expand_path(path).start_with?("#{@root}/")
          raise InvalidKey, "key escapes the storage root"
        end
        path
      end

      def existing_file_path(key)
        path = path_for(validate_key(key))
        raise NotFound, "blob not found: #{key}" unless File.file?(path)

        path
      end

      # rename(2)s +tmp+ onto +path+, creating missing parent directories.
      # A concurrent #delete may prune a parent between mkdir_p and rename
      # (ENOENT); that is retried a few times, since the next mkdir_p simply
      # recreates the directory. Other failures (a file where a directory is
      # needed, etc.) are left to the caller.
      def move_into_place(tmp, path)
        attempts = 0
        begin
          FileUtils.mkdir_p(File.dirname(path))
          File.rename(tmp, path)
        rescue Errno::ENOENT
          raise if (attempts += 1) > RENAME_RETRIES

          retry
        end
      end

      # Removes now-empty directories from +path+'s parent up to (excluding)
      # the storage root. Stops at the first directory that is not empty or
      # that disappeared/changed under us: a concurrent #put may have just
      # placed something there, which is exactly when we must leave it alone.
      def prune_empty_parents(path)
        dir = File.dirname(path)
        while dir.start_with?("#{@root}/")
          Dir.rmdir(dir)
          dir = File.dirname(dir)
        end
      rescue SystemCallError
        # ENOTEMPTY / EEXIST: directory is in use again; ENOENT: already gone;
        # anything else (EACCES, EBUSY, ...): not worth failing the delete for.
        nil
      end

      def mtime_of(path)
        File.mtime(path).utc.iso8601(3)
      end

      def sha256_of(path)
        Digest::SHA256.file(path).hexdigest
      end
    end
  end
end
