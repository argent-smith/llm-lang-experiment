# frozen_string_literal: true

require "time"

module Syncbox
  module Client
    # syncbox sync: push and pull in one pass. Every file present on one side
    # only is copied to the other; a file both sides hold with different
    # content (by SHA-256) is copied from the side that changed it since the
    # last sync to the side that did not. If both changed it (or there was no
    # common version to tell by, as on the first sync), the more recent
    # version wins: the server's modified_at against the local mtime, and the
    # local version on a tie ("Conflict resolution rule for sync" in
    # SYNCBOX-SPEC.md).
    #
    # The last common version of each file is what the directory and the
    # server held identically after the previous sync (SyncState). Nothing is
    # deleted on either side: a file missing on one side is copied there again.
    #
    # As in push and pull, symlinks and special files are skipped with a
    # warning, and the server's keys are checked before anything is changed.
    class Sync
      # One file's outcome: +direction+ is :upload, :download or :none (the
      # sides are identical already, +sha256+ being their content); +note+
      # says how a conflict was resolved.
      Step = Data.define(:key, :direction, :file, :blob, :sha256, :note) do
        def initialize(key:, direction:, file: nil, blob: nil, sha256: nil, note: nil) = super
      end

      LOCAL_NEWER = "conflict: local copy is newer"
      SERVER_NEWER = "conflict: server copy is newer"
      SAME_TIME = "conflict: same modification time, local copy wins"

      # +server+ tells the servers the directory is synced with apart in its
      # state.
      def initialize(dir, remote, server:, out:, err:)
        @dir = dir
        @remote = remote
        @server = server
        @out = out
        @err = err
      end

      def run
        raise Error, "not a directory: #{@dir}" unless File.directory?(@dir)

        state = SyncState.load(@dir)
        common = state.common(@server)
        skipped = Set.new
        files = LocalTree.new(@dir).files do |key, reason|
          skipped << key
          @err.puts "syncbox: skipping #{key}: #{reason}"
        end
        files = files.to_h { |file| [file.key, file] }
        blobs = Pull.check_keys(@remote.list.values).to_h { |blob| [blob.key, blob] }
        pull = Pull.new(@dir, @remote, out: @out, err: @err)

        # Everything is looked at (and hashed) before anything is changed, so
        # that a local obstacle fails the sync before it has done half its work.
        steps = (files.keys | blobs.keys).sort.filter_map do |key|
          next if skipped.include?(key)

          file = files[key]
          # A blob without a file in the listing: look where pull would write
          # it, so that whatever pull would skip or fail on is skipped or fails
          # here too.
          file ||= pull.local_file(key)
          if file == :skipped
            skipped << key
            next
          end

          plan(key, file, blobs[key], common[key])
        end

        synced = {}
        counts = Hash.new(0)
        steps.each do |step|
          sha256 = transfer(step, pull)
          if sha256.nil?
            skipped << step.key
            next
          end

          synced[step.key] = sha256
          counts[step.direction] += 1
        end
        # What was skipped is as (un)known as it was before.
        state.update(@server, common.slice(*skipped).merge(synced).sort.to_h)
        @out.puts "sync: #{counts[:upload]} uploaded, #{counts[:download]} downloaded, #{counts[:none]} up to date"
      end

      private

      # The Step for +key+, held locally as +file+ and on the server as +blob+
      # (either may be nil), last common to both with content +base+ (nil if
      # unknown).
      def plan(key, file, blob, base)
        return Step.new(key: key, direction: :upload, file: file) if blob.nil?
        return Step.new(key: key, direction: :download, blob: blob) if file.nil?

        local = reading(file) { file.sha256 }
        if local == blob.sha256
          Step.new(key: key, direction: :none, sha256: local)
        elsif base == local # only the server's copy changed
          Step.new(key: key, direction: :download, blob: blob)
        elsif base == blob.sha256 # only the local copy changed
          Step.new(key: key, direction: :upload, file: file, sha256: local)
        else
          conflict(key, file, blob, local)
        end
      end

      # Both sides changed the file: the more recent version wins, the local
      # one if both are as recent. The local mtime is compared at the
      # precision of the server's timestamp: a server that lists whole
      # seconds cannot tell a file modified at 12:00:00.4 from one modified
      # at 12:00:00.
      def conflict(key, file, blob, local)
        server_time, digits = server_time(blob)
        local_time = reading(file) { File.lstat(file.path).mtime }.floor(digits)
        if local_time > server_time
          Step.new(key: key, direction: :upload, file: file, sha256: local, note: LOCAL_NEWER)
        elsif local_time == server_time
          Step.new(key: key, direction: :upload, file: file, sha256: local, note: SAME_TIME)
        else
          Step.new(key: key, direction: :download, blob: blob, note: SERVER_NEWER)
        end
      end

      # The blob's modified_at as a Time, and the number of its fractional
      # second digits.
      def server_time(blob)
        time = Time.iso8601(blob.modified_at)
        [time, blob.modified_at[/T[^.,]*[.,](\d+)/, 1].to_s.size]
      rescue ArgumentError, TypeError
        raise Error, "server listed an invalid modified_at for #{blob.key}: #{blob.modified_at.inspect}"
      end

      # Carries out the step and returns the content both sides then hold,
      # or nil if the blob was deleted from the server meanwhile.
      def transfer(step, pull)
        case step.direction
        when :upload
          stored = reading(step.file) { step.file.open { |io| @remote.put(step.key, io) } }
          report("uploaded", step)
          stored || step.sha256 || reading(step.file) { step.file.sha256 }
        when :download
          pull.download(step.blob).tap { report("downloaded", step) }
        else
          step.sha256
        end
      rescue Remote::NotFound
        @err.puts "syncbox: skipping #{step.key}: deleted from the server meanwhile"
        nil
      end

      def report(done, step)
        @out.puts step.note ? "#{done} #{step.key} (#{step.note})" : "#{done} #{step.key}"
      end

      # Reports a local read error by key: the directory's own path may mean
      # nothing to the user (inside the client container it is a mount point).
      def reading(file)
        yield
      rescue SystemCallError => e
        raise Error, "cannot read #{file.key}: #{e.class.new.message}"
      end
    end
  end
end
