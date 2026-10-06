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

          FileUtils.mkdir_p(File.dirname(path))
          File.rename(tmp, path)
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

      # Raises InvalidKey for unsafe keys and NotFound for missing keys.
      def delete(key)
        path = existing_file_path(key)
        File.unlink(path)
      rescue Errno::ENOENT, *UNREPRESENTABLE_KEY_ERRORS
        raise NotFound, "blob not found: #{key}"
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

      def mtime_of(path)
        File.mtime(path).utc.iso8601(3)
      end

      def sha256_of(path)
        Digest::SHA256.file(path).hexdigest
      end
    end
  end
end
