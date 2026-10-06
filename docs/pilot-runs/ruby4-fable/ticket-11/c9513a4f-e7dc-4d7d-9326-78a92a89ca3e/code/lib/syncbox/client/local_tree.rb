# frozen_string_literal: true

require "digest"
require "set"

module Syncbox
  module Client
    # The local side of a sync: maps keys to paths inside one directory and
    # hashes files.
    #
    # #scan walks the directory recursively: every regular file becomes a
    # LocalFile whose key is its POSIX path relative to the directory (the
    # same convention the server uses) and whose sha256 is the hex digest of
    # its contents. Symlinks (to files or directories) and special files
    # (sockets, FIFOs, devices) cannot be represented as blobs and are
    # skipped with a warning — symlinks are never followed, so a link cannot
    # drag anything from outside the directory into the upload or create a
    # cycle. Hidden entries are ordinary files and are included.
    #
    # An entry that cannot be turned into a LocalFile — a file that cannot be
    # read, a directory that cannot be listed (its files are unknown), a name
    # that is not valid UTF-8 and so cannot be a key (the server rejects it)
    # — is a failure of that entry, not of the scan: with an +on_failure+
    # handler it is reported there and the walk continues with the next
    # entry (the spec's partial-failure rule); without one the first such
    # entry raises Error. Only the directory itself being unreadable, or not
    # a directory, is always an Error — there is nothing to continue with.
    #
    # #lookup / #path_for go the other way, from a key (as listed by the
    # server) to the local path it stands for, with the same rule applied in
    # reverse: a key never resolves through a symlink, and a key that could
    # leave the directory is refused.
    #
    # The top-level entry STATE_DIR (".syncbox") is reserved for the client's
    # own bookkeeping (see SyncState): the scan never descends into it, and a
    # key under it is refused, so it is neither uploaded nor written to by a
    # download.
    class LocalTree
      # +key+ names the entry the error is about (nil for the directory as a
      # whole); for a name that is not valid UTF-8 it is the raw name.
      class Error < Client::Error
        attr_accessor :key
      end

      CHUNK_SIZE = 64 * 1024
      STATE_DIR = ".syncbox"

      # +mtime+ is the file's modification time, read when it was hashed.
      LocalFile = Struct.new(:key, :path, :size, :sha256, :mode, :mtime, keyword_init: true)

      # True if +key+ is, or lies under, the reserved STATE_DIR entry.
      def self.reserved?(key)
        key == STATE_DIR || key.start_with?("#{STATE_DIR}/")
      end

      # Yields a warning message for every skipped entry; returns the files
      # sorted by key. See #scan for +on_failure+.
      def self.scan(dir, on_failure: nil, &on_warning)
        new(dir).scan(on_failure: on_failure, &on_warning)
      end

      attr_reader :root

      def initialize(dir)
        @root = File.expand_path(dir)
        @verified_dirs = Set.new
      end

      # Walks the directory (see the class comment). +on_failure+, if given,
      # is called with (key, message) for every entry that could not be
      # scanned, and the walk goes on; without it the first such entry raises
      # Error. The block receives a warning for every skipped entry.
      def scan(on_failure: nil, &on_warning)
        require_directory!

        files = []
        names = begin
          Dir.children(@root)
        rescue SystemCallError => e
          raise Error, "cannot read #{@root}: #{e.message}"
        end
        walk(@root, names, files, on_failure, on_warning)
        files.sort_by!(&:key)
      end

      def require_directory!
        raise Error, "not a directory: #{@root}" unless File.directory?(@root)
      end

      # The LocalFile currently stored under +key+, or nil if there is none.
      # Anything other than a regular file at that path (a directory, a
      # symlink — never followed —, a socket) is an Error: the key cannot be
      # compared with, or written over, such an entry.
      def lookup(key)
        path = path_for(key)
        stat = File.lstat(path)
        return file_entry(key, path) if stat.file?

        kind = stat.symlink? ? "a symbolic link" : stat.directory? ? "a directory" : "a #{stat.ftype}"
        raise Error, "#{key}: #{kind} is in the way of the file"
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Error, "#{key}: #{e.message}"
      end

      # The absolute path a key stands for. Keys come from the server and are
      # not trusted: one that is absolute, contains "." or ".." segments,
      # empty segments or NUL bytes is refused rather than resolved. Every
      # existing ancestor of the path must be a real directory — a symlink in
      # the way is refused, so a key can never write outside the directory
      # through a link, and a file in the way is refused with a clear message
      # instead of a failing mkdir.
      def path_for(key)
        validate_key(key)
        path = File.join(@root, key)
        verify_ancestors(File.dirname(path), key)
        path
      end

      private

      def validate_key(key)
        utf8 = key.dup.force_encoding(Encoding::UTF_8)
        raise Error, "refusing key #{key.inspect} from the server: not valid UTF-8" unless utf8.valid_encoding?
        raise Error, "refusing key #{key.inspect} from the server: contains a NUL byte" if key.include?("\0")
        raise Error, "refusing key #{key.inspect} from the server: absolute path" if key.start_with?("/")

        segments = key.split("/", -1)
        if segments.empty? || segments.any?(&:empty?)
          raise Error, "refusing key #{key.inspect} from the server: empty path segment"
        end
        if segments.any? { |s| s == "." || s == ".." }
          raise Error, "refusing key #{key.inspect} from the server: contains a . or .. segment"
        end
        if self.class.reserved?(key)
          raise Error, "refusing key #{key.inspect} from the server: #{STATE_DIR} is reserved for syncbox's own state"
        end
      end

      # Checks every directory between the root and +dir+ (inclusive), from
      # the top down, stopping at the first one that does not exist yet (its
      # descendants cannot exist either). Verified directories are remembered
      # for the lifetime of this tree, so a pull checks each one once.
      def verify_ancestors(dir, key)
        chain = []
        current = dir
        while current != @root && !@verified_dirs.include?(current)
          chain.unshift(current)
          current = File.dirname(current)
        end

        chain.each do |candidate|
          stat = begin
            File.lstat(candidate)
          rescue Errno::ENOENT
            return # does not exist yet: it will be created, nothing to verify
          end
          if stat.symlink?
            raise Error, "#{key}: a symbolic link is in the way (#{relative(candidate)}); links are not followed"
          elsif !stat.directory?
            raise Error, "#{key}: #{relative(candidate)} is in the way and is not a directory"
          end
          @verified_dirs << candidate
        end
      rescue SystemCallError => e
        raise Error, "#{key}: #{e.message}"
      end

      # One directory level of the scan: +names+ are the entries of +dir+.
      # Entries are visited in name order so that failures are reported in a
      # stable order; the files are sorted by key at the end anyway.
      def walk(dir, names, files, on_failure, on_warning)
        names.sort.each do |name|
          path = File.join(dir, name)
          key = key_for(path)
          next if dir == @root && key == STATE_DIR # the client's own state, never a blob

          stat = File.lstat(path)
          if stat.symlink?
            on_warning&.call("skipping #{key}: symbolic links are not uploaded")
          elsif stat.directory?
            walk(path, Dir.children(path), files, on_failure, on_warning)
          elsif stat.file?
            files << file_entry(key, path)
          else
            on_warning&.call("skipping #{key}: not a regular file (#{stat.ftype})")
          end
        rescue Error => e
          raise unless on_failure

          on_failure.call(e.key || key_for(path, strict: false), e.message)
        rescue SystemCallError => e
          # lstat or Dir.children failed on this entry (permissions, or it
          # vanished between the listing and the stat).
          failure = Error.new("cannot read #{relative(path)}: #{e.message}")
          failure.key = key_for(path, strict: false)
          raise failure unless on_failure

          on_failure.call(failure.key, failure.message)
        end
      end

      def relative(path)
        path.byteslice((@root.bytesize + 1)..).to_s
      end

      # The key for an absolute path under the root. A name that is not valid
      # UTF-8 cannot be a key: Error when +strict+, the (invalid) string
      # itself otherwise — for naming the entry in a failure report.
      def key_for(path, strict: true)
        key = path.byteslice((@root.bytesize + 1)..).dup.force_encoding(Encoding::UTF_8)
        return key if key.valid_encoding? || !strict

        failure = Error.new("file name is not valid UTF-8 and cannot be a key: #{key.inspect}")
        failure.key = key
        raise failure
      end

      def file_entry(key, path)
        digest = Digest::SHA256.new
        size = 0
        mode = nil
        mtime = nil
        File.open(path, "rb") do |file|
          stat = file.stat
          mode = stat.mode & 0o7777
          mtime = stat.mtime
          while (chunk = file.read(CHUNK_SIZE))
            digest << chunk
            size += chunk.bytesize
          end
        end
        LocalFile.new(key: key, path: path, size: size, sha256: digest.hexdigest, mode: mode, mtime: mtime)
      rescue SystemCallError => e
        failure = Error.new("cannot read #{key}: #{e.message}")
        failure.key = key
        raise failure
      end
    end
  end
end
