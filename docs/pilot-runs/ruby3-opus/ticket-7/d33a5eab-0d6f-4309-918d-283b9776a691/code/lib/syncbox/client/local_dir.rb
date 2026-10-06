# frozen_string_literal: true

require "digest"

module Syncbox
  module Client
    # The files of a local directory tree, named by blob key: the file's
    # relative POSIX path inside the directory (docs/readme.txt).
    class LocalDir
      Entry = Data.define(:key, :path)

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

      private

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
