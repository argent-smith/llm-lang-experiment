# frozen_string_literal: true

require "digest"
require "securerandom"

module Syncbox
  module Client
    # The files of a local directory tree, named by blob key: the file's
    # relative POSIX path inside the directory (docs/readme.txt).
    class LocalDir
      Entry = Data.define(:key, :path)
      # Where a key's file goes: stat is the File::Stat of the regular file
      # already there, or nil if there is none yet.
      Target = Data.define(:key, :path, :stat)

      # A file is in the way of one of a key's directories, or a directory
      # is where its file would go.
      class PathConflict < Error
        attr_reader :key, :reason

        def initialize(key, reason)
          super("cannot write #{key}: #{reason}")
          @key = key
          @reason = reason
        end
      end

      # Downloads are staged next to their file under such names.
      STAGING_PREFIX = ".syncbox-"
      STAGING_SUFFIX = ".part"

      # Whether key names a path inside the directory: a relative POSIX path
      # of valid UTF-8 without NUL and without empty, "." or ".." segments,
      # the same rule the server applies.
      def self.valid_key?(key)
        key.is_a?(String) && !key.empty? && key.encoding == Encoding::UTF_8 && key.valid_encoding? &&
          !key.include?("\0") && key.split("/", -1).none? { |s| s.empty? || s == "." || s == ".." }
      end

      # An error's description without the (container-side) path it names.
      def self.reason(error)
        error.is_a?(SystemCallError) ? SystemCallError.new(nil, error.errno).message : error.message
      end

      # SHA-256 (hex) of an entry's contents.
      def self.sha256(entry)
        Digest::SHA256.file(entry.path).hexdigest
      rescue SystemCallError, IOError => e
        raise Error, "cannot read #{entry.key}: #{reason(e)}"
      end

      # on_skip is called with (relative path, reason) for each entry that
      # can't be synced: symlinks, special files, names that aren't UTF-8.
      def initialize(root, on_skip: nil)
        @root = root
        @on_skip = on_skip || ->(_path, _reason) {}
      end

      # Every regular file under root, sorted by key. Symlinks are not
      # followed, just like the server never follows them in its store.
      def entries
        raise Error, "#{@root}: no such directory" unless File.exist?(@root)
        raise Error, "#{@root}: not a directory" unless File.directory?(@root)

        found = []
        # Iterative walk, so deep trees can't exhaust the stack.
        pending = [[@root.b, nil]]
        until pending.empty?
          dir, prefix = pending.pop
          children(dir, prefix).each do |raw_name|
            path = File.join(dir, raw_name)
            rel = prefix ? "#{prefix}/#{raw_name}".b : raw_name
            stat = lstat(path, rel)
            next unless stat

            key = rel.dup.force_encoding(Encoding::UTF_8)
            if !key.valid_encoding?
              @on_skip.call(key.scrub, "name is not valid UTF-8")
            elsif stat.directory?
              pending << [path, rel]
            elsif stat.file?
              found << Entry.new(key: key, path: path)
            elsif stat.symlink?
              @on_skip.call(key, "symbolic link")
            else
              @on_skip.call(key, "not a regular file")
            end
          end
        end
        found.sort_by(&:key)
      end

      # The directory's path with symlinks resolved (the directory itself
      # may be one). Raises Error if it is missing or not a directory.
      def real_root
        @real_root ||= begin
          raise Error, "#{@root}: no such directory" unless File.exist?(@root)
          raise Error, "#{@root}: not a directory" unless File.directory?(@root)

          File.realpath(@root).b
        rescue SystemCallError => e
          raise Error, "cannot read directory #{@root}: #{self.class.reason(e)}"
        end
      end

      # The Target for writing key's file, or nil (reported via on_skip) if
      # key isn't a valid key, or writing there would mean following or
      # replacing a symlink or replacing a special file: as when walking,
      # symlinks are never followed, so nothing is written outside the
      # directory. Raises PathConflict if a file is in the way of one of the
      # key's directories, or a directory is where its file would go. Only
      # looks: nothing is created.
      def target(key)
        unless self.class.valid_key?(key)
          # The key came from elsewhere and may not even be printable.
          @on_skip.call(key.inspect, "not a valid key")
          return nil
        end

        segments = key.split("/")
        path = real_root
        segments.each_with_index do |segment, i|
          path = File.join(path, segment.b)
          rel = segments[0..i].join("/")
          stat = lstat(path, rel)
          last = i == segments.size - 1
          if stat.nil?
            # Nothing there: the rest of the path is created when writing.
            return Target.new(key: key, path: File.join(real_root, key.b), stat: nil)
          elsif stat.symlink?
            @on_skip.call(key, last ? "symbolic link" : "#{rel} is a symbolic link")
            return nil
          elsif !last && !stat.directory?
            raise PathConflict.new(key, "#{rel} is not a directory")
          elsif last && stat.directory?
            raise PathConflict.new(key, "it is a directory")
          elsif last && !stat.file?
            @on_skip.call(key, "not a regular file")
            return nil
          elsif last
            return Target.new(key: key, path: path, stat: stat)
          end
        end
      end

      # Replaces target's file with what the block writes to the IO it is
      # given. The contents are staged in a file next to it and renamed over
      # it only once complete, so the file is never seen half-written and is
      # left as it was if the block raises. Missing parent directories are
      # created; a replaced file keeps its permissions.
      def write(target)
        dir = File.dirname(target.path)
        make_parent_dirs(target.key)
        staged = File.join(dir, "#{STAGING_PREFIX}#{SecureRandom.hex(8)}#{STAGING_SUFFIX}")
        File.open(staged, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW | File::BINARY, 0o666) do |file|
          yield file
          file.chmod(target.stat.mode & 0o7777) if target.stat
          file.fsync
        end
        # A symlink swapped into the path meanwhile must not carry the file
        # outside the directory.
        unless File.realpath(dir).b == File.dirname(File.join(real_root, target.key.b))
          raise Error, "cannot write #{target.key}: its directory has moved"
        end

        File.rename(staged, target.path)
        staged = nil
      rescue SystemCallError, IOError => e
        raise Error, "cannot write #{target.key}: #{self.class.reason(e)}"
      ensure
        begin
          File.unlink(staged) if staged
        rescue SystemCallError
          nil # never created, or already gone
        end
      end

      private

      def make_parent_dirs(key)
        path = real_root
        key.split("/")[0...-1].each do |segment|
          path = File.join(path, segment.b)
          begin
            Dir.mkdir(path)
          rescue Errno::EEXIST
            nil # checked by target; anything else fails when writing
          end
        end
      end

      def children(dir, rel)
        Dir.children(dir, encoding: Encoding::BINARY)
      rescue SystemCallError => e
        raise Error, "cannot read directory #{rel ? display(rel) : @root}: #{self.class.reason(e)}"
      end

      def lstat(path, rel)
        File.lstat(path)
      rescue Errno::ENOENT
        nil # removed while walking
      rescue SystemCallError => e
        raise Error, "cannot read #{display(rel)}: #{self.class.reason(e)}"
      end

      def display(rel)
        rel.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
