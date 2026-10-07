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
    #   <data_dir>/tmp/          staging area for writes in progress
    #
    # == Atomic writes
    #
    # #put never writes to the target file. The body is streamed into a
    # freshly created staging file (<data_dir>/tmp/put-<random>), flushed and
    # fsync(2)ed, and only then rename(2)d onto <data_dir>/blobs/<key>.
    # rename(2) swaps the directory entry atomically, so a reader that opens
    # the key at any moment gets either the previous complete file or the
    # new complete one — never a partially written one — and a reader that
    # already holds the old file open reads it to the end even though its
    # directory entry is gone. Concurrent #put calls for the same key each
    # stage into their own randomly named file; the last rename wins and the
    # losers' versions are unlinked whole. Concurrent #put calls for
    # different keys share nothing but the staging directory.
    #
    # The staging directory is a sibling of the storage root inside the same
    # data dir, i.e. on the same filesystem: rename(2) across filesystems is
    # impossible (EXDEV) and a copy would not be atomic. #prepare and #put
    # verify this (same st_dev) rather than assume it, and refuse to write
    # otherwise.
    #
    # The staging file is removed in every outcome — success, rejected key,
    # I/O failure, aborted body — and #prepare sweeps whatever a process that
    # died mid-write left behind. Staging files are never blobs: tmp/ lies
    # outside the storage root, so they are neither listed nor reachable
    # through any key (see #path_for).
    #
    # == Directories
    #
    # Directories under <data_dir>/blobs/ exist only as long as they hold a
    # blob: #put creates them on demand and #delete removes the ones it leaves
    # empty, so a key whose last blob was deleted behaves exactly like a key
    # that never existed (in particular, it can be reused as a file name).
    #
    # == Keys
    #
    # A key is a POSIX path relative to the storage root. Every public method
    # takes the *decoded* key and runs it through two independent checks
    # before touching the file it names:
    #
    # * #validate_key — lexical: anything that cannot be a safe relative file
    #   name (".." or "." segments, absolute path, empty segment, NUL, invalid
    #   UTF-8, over-long segment) raises InvalidKey.
    # * #path_for — on disk: the location the path actually resolves to
    #   (symlinks in every existing ancestor followed, realpath(3)-style) must
    #   lie strictly inside the storage root, otherwise InvalidKey. This is
    #   what makes the traversal protection hold even for a well-formed key
    #   whose ancestor on disk turns out to be a symlink pointing elsewhere.
    class BlobStore
      class Error < StandardError; end
      class InvalidKey < Error; end
      class NotFound < Error; end

      MAX_SEGMENT_BYTES = 255
      CHUNK_SIZE = 64 * 1024
      RENAME_RETRIES = 3
      RESOLVE_RETRIES = 8

      # Staging files are "put-" followed by 32 hex digits (128 random bits),
      # so two writers can never pick the same name.
      STAGING_PREFIX = "put-"
      STAGING_NAME = /\Aput-\h{32}\z/

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

      attr_reader :root, :staging_dir

      def initialize(data_dir)
        @root = File.join(File.expand_path(data_dir), "blobs")
        @staging_dir = File.join(File.expand_path(data_dir), "tmp")
      end

      # Prepares the store for serving: creates the storage root and the
      # staging directory, checks that they share a filesystem (raises Error
      # otherwise — rename(2) between them could not be atomic) and removes
      # staging files left behind by a previous process that died mid-write.
      #
      # Meant to be called once at boot. A single server process owns the
      # data dir, so nothing in tmp/ can still be in use at that point.
      # Returns the number of stale staging files removed.
      def prepare
        ensure_directories
        Dir.children(@staging_dir).count do |name|
          next false unless STAGING_NAME.match?(name.b)

          discard(File.join(@staging_dir, name))
          true
        end
      end

      # Raises InvalidKey unless +key+ is a safe relative path; returns +key+
      # as a UTF-8 string. Purely lexical — see #path_for for the on-disk half.
      def validate_key(key)
        raise InvalidKey, "key must not be empty" if key.nil? || key.empty?

        key = key.dup.force_encoding(Encoding::UTF_8)
        raise InvalidKey, "key is not valid UTF-8" unless key.valid_encoding?
        raise InvalidKey, "key must not contain NUL" if key.include?("\0")
        raise InvalidKey, "key must be relative" if key.start_with?("/")

        key.split("/", -1).each do |segment|
          raise InvalidKey, "key must not contain empty segments" if segment.empty?
          raise InvalidKey, "key must not contain . or .. segments" if [".", ".."].include?(segment)
          raise InvalidKey, "key segment too long" if segment.bytesize > MAX_SEGMENT_BYTES
        end

        key
      end

      # Streams +io+ (anything responding to #read(len)) into the blob for
      # +key+, replacing any previous contents atomically (see the class
      # comment). Returns a Meta describing exactly the version written:
      # +modified_at+ is the staged file's mtime, which rename(2) preserves.
      def put(key, io)
        key = validate_key(key)
        path = path_for(key)
        ensure_directories

        tmp = File.join(@staging_dir, "#{STAGING_PREFIX}#{SecureRandom.hex(16)}")
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
          modified_at = iso8601(File.mtime(tmp))

          move_into_place(tmp, path)
        rescue Errno::EXDEV
          raise Error, "cannot move staged blob into place: #{File.dirname(path)} is on a different " \
                       "filesystem than #{@staging_dir}, so rename(2) is impossible"
        rescue *UNREPRESENTABLE_KEY_ERRORS => e
          raise InvalidKey, "key cannot be stored as a file: #{e.message}"
        ensure
          # Gone already on success (renamed away); otherwise — body read
          # failed, rename failed, key rejected — the half-written staging
          # file must not outlive the request.
          discard(tmp)
        end

        Meta.new(key: key, size: size, sha256: digest.hexdigest, modified_at: modified_at)
      end

      # Opens the blob for reading and yields [File, size]. The size comes
      # from the open descriptor (fstat), so it describes the very file being
      # read even if the key is replaced concurrently. Raises InvalidKey for
      # unsafe keys and NotFound for missing keys or keys that are not
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

      # All stored blobs with metadata, sorted by key. Only regular files whose
      # real location is inside the storage root count: a symlink that leads
      # out of the root is not a blob (and could not be fetched anyway).
      # Each entry's size, sha256 and modified_at are taken from one open
      # file, so they describe a single version even under concurrent #put.
      def list
        return [] unless File.directory?(@root)

        real_root = resolve_on_disk(@root)
        entries = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).filter_map do |rel|
          rel = rel.dup.force_encoding(Encoding::UTF_8)
          next unless rel.valid_encoding?
          next if rel.split("/").include?(".")

          path = File.join(@root, rel)
          begin
            next unless File.file?(path)
            next unless inside?(real_root, File.realpath(path))

            meta_of(rel, path)
          rescue Errno::ENOENT, *UNREPRESENTABLE_KEY_ERRORS
            nil # vanished or changed shape between glob and open; skip
          end
        end
        entries.sort_by(&:key)
      end

      private

      # Creates the storage root and the staging directory (idempotent) and
      # checks that they live on the same filesystem, which is what makes
      # rename(2) from one to the other atomic. Cheap (two stat calls), so
      # #put does it every time rather than trusting a boot-time check.
      def ensure_directories
        FileUtils.mkdir_p(@root)
        FileUtils.mkdir_p(@staging_dir)
        return if File.stat(@root).dev == File.stat(@staging_dir).dev

        raise Error, "staging directory #{@staging_dir} is not on the same filesystem as the storage " \
                     "root #{@root}; rename(2) between them cannot be atomic"
      end

      # Removes a staging file; a file that is already gone (renamed into
      # place) is fine.
      def discard(tmp)
        File.unlink(tmp)
      rescue Errno::ENOENT
        nil
      end

      # Metadata of the regular file at +path+, all taken from a single open
      # descriptor. Returns nil if what is there is not a regular file.
      def meta_of(key, path)
        File.open(path, "rb") do |file|
          stat = file.stat
          return nil unless stat.file?

          digest = Digest::SHA256.new
          while (chunk = file.read(CHUNK_SIZE))
            digest << chunk
          end
          Meta.new(key: key, size: stat.size, sha256: digest.hexdigest, modified_at: iso8601(stat.mtime))
        end
      end

      # Lexical path of +key+ under the storage root, after checking that the
      # place it resolves to on disk lies strictly inside that root.
      #
      # validate_key already rules out ".." and absolute paths, so the path
      # cannot escape lexically; the remaining way out is a symlink in one of
      # its existing ancestors. Both the path and the root are therefore
      # resolved the same way (see #resolve_on_disk) and compared as strings.
      # Read-only: nothing is created or followed beyond stat(2)/realpath(3).
      def path_for(key)
        path = File.join(@root, key)
        resolved = resolve_on_disk(path)
        raise InvalidKey, "key escapes the storage root" unless inside?(resolve_on_disk(@root), resolved)

        path
      end

      # realpath(3) of the longest existing prefix of +path+, with the missing
      # tail appended lexically. The tail is safe to append as-is because it
      # has passed validate_key (no ".", "..", empty segments). A dangling
      # symlink or a symlink cycle counts as missing: it resolves nowhere, so
      # it cannot lead out of the root either.
      #
      # The prefix found by stat(2) may be pruned by a concurrent #delete
      # before realpath(3) looks at it (ENOENT); the walk is then simply
      # repeated from the top.
      def resolve_on_disk(path)
        attempts = 0
        begin
          missing = []
          existing = path
          until File.exist?(existing)
            missing.unshift(File.basename(existing))
            existing = File.dirname(existing)
          end
          File.join(File.realpath(existing), *missing)
        rescue Errno::ENOENT
          raise InvalidKey, "key cannot be resolved on disk: #{path}" if (attempts += 1) > RESOLVE_RETRIES

          retry
        rescue SystemCallError => e
          # ELOOP, ENAMETOOLONG after expansion, EACCES, ...: if it cannot be
          # resolved, it cannot be proven to stay inside the root.
          raise InvalidKey, "key cannot be resolved on disk: #{e.message}"
        end
      end

      # Whether +path+ is strictly below +root+ (both already resolved).
      def inside?(root, path)
        path.start_with?("#{root}/")
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

      def iso8601(time)
        time.utc.iso8601(3)
      end
    end
  end
end
