# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Syncbox
  module Client
    # syncbox pull: downloads the blobs that the local directory lacks or
    # holds with different content, each to the relative path its key names.
    # Files identical to the stored blob (by SHA-256) are not downloaded
    # again; local files without a blob are left alone.
    #
    # The keys come from the server and are not trusted: a key must name a
    # path inside the directory, and no symlink in the directory is followed
    # on the way to it. As in push, symlinks and special files are not synced:
    # a blob whose path runs into one is skipped with a warning.
    class Pull
      # Prefix of the temporary files downloads are written to before being
      # renamed into place. They are created next to their target: rename is
      # atomic only within one file system.
      TMP_PREFIX = ".syncbox-pull-"

      # Whether +key+ is a relative POSIX path of non-empty segments other
      # than "." and "..", in valid UTF-8 and without NUL bytes.
      def self.safe_key?(key)
        key.is_a?(String) && !key.empty? && key.valid_encoding? && !key.include?("\0") &&
          key.split("/", -1).none? { |segment| segment.empty? || segment == "." || segment == ".." }
      end

      def initialize(dir, remote, out:, err:)
        @dir = dir
        @remote = remote
        @out = out
        @err = err
      end

      def run
        raise Error, "not a directory: #{@dir}" unless File.directory?(@dir)

        blobs = @remote.list.values.sort_by(&:key)
        unsafe = blobs.find { |blob| !self.class.safe_key?(blob.key) }
        raise Error, "server listed a key that is not a path inside the directory: #{unsafe.key.inspect}" if unsafe

        plan = blobs.group_by { |blob| state(blob) }
        downloaded = 0
        plan.fetch(:changed, []).each do |blob|
          download(blob)
          downloaded += 1
          @out.puts "downloaded #{blob.key}"
        rescue Remote::NotFound
          @err.puts "syncbox: skipping #{blob.key}: deleted from the server meanwhile"
        end
        @out.puts "pull: #{downloaded} downloaded, #{plan.fetch(:up_to_date, []).size} up to date"
      end

      private

      # :up_to_date if the local file already holds the blob's content,
      # :skipped if a symlink or special file is in the way, :changed otherwise.
      def state(blob)
        file = local_file(blob.key)
        return file if file.is_a?(Symbol)

        # The size is compared first only to skip hashing files that differ anyway.
        same = blob.size == file.size && blob.sha256 == local(blob.key, "read") { file.sha256 }
        same ? :up_to_date : :changed
      end

      # The regular file at the blob's path, :changed if there is none, or
      # :skipped (with a warning) if a symlink or special file is in the way.
      # Raises Error if a directory is where the file should be, or a file
      # where a directory should be.
      def local_file(key)
        segments = key.split("/")
        path = @dir
        segments.each_with_index do |segment, i|
          path = File.join(path, segment)
          stat = lstat(key, path)
          return :changed if stat.nil?

          last = i == segments.size - 1
          if last && stat.file?
            return LocalTree::LocalFile.new(key: key, path: path, size: stat.size)
          elsif last && stat.directory?
            raise Error, "cannot write #{key}: a directory is in the way"
          elsif stat.file?
            raise Error, "cannot write #{key}: #{segments[..i].join('/')} is a file, not a directory"
          elsif !stat.directory?
            @err.puts "syncbox: skipping #{key}: #{segments[..i].join('/')} is a " \
                      "#{stat.symlink? ? 'symbolic link' : 'special file'}"
            return :skipped
          end
        end
      end

      # nil if there is nothing at +path+.
      def lstat(key, path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError => e
        raise Error, "cannot read #{key}: #{e.class.new.message}"
      end

      # Writes the blob to a temporary file next to its path and renames it
      # into place, so the file is never seen half-written. A replaced file
      # keeps its permissions.
      def download(blob)
        key = blob.key
        parent = local(key) { make_parents(key) }
        path = File.join(parent, File.basename(key))
        tmp = File.join(parent, "#{TMP_PREFIX}#{SecureRandom.hex(8)}")
        file = local(key) { File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::BINARY) }
        begin
          # Write errors are wrapped right away: Remote would take a
          # SystemCallError raised from the block for a network error.
          @remote.get(key) { |chunk| local(key) { file.write(chunk) } }
          local(key) do
            file.fsync
            file.close
            mode = existing_mode(path)
            File.chmod(mode, tmp) if mode
            File.rename(tmp, path)
          end
        ensure
          file.close
          FileUtils.rm_f(tmp)
        end
      end

      # Creates the missing directories on the way to the blob's path and
      # returns the path of its parent. Raises Error if anything else is in
      # the way, including a symlink that appeared since the check.
      def make_parents(key)
        segments = key.split("/")[...-1]
        path = @dir
        segments.each_with_index do |segment, i|
          path = File.join(path, segment)
          Dir.mkdir(path)
        rescue Errno::EEXIST
          next if File.lstat(path).directory?

          raise Error, "cannot write #{key}: #{segments[..i].join('/')} is not a directory"
        end
        path
      end

      def existing_mode(path)
        stat = File.lstat(path)
        stat.mode & 0o7777 if stat.file?
      rescue Errno::ENOENT
        nil
      end

      # Reports a local file system error by key: the directory's own path
      # may mean nothing to the user (inside the client container it is a
      # mount point).
      def local(key, action = "write")
        yield
      rescue SystemCallError => e
        raise Error, "cannot #{action} #{key}: #{e.class.new.message}"
      end
    end
  end
end
