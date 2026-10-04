# frozen_string_literal: true

require "digest"
require "time"

module Syncbox
  module Client
    # syncbox sync: push and pull in one pass. Every file that exists on one
    # side only is copied to the other; for a file whose contents (SHA-256)
    # differ, SyncState tells which side changed since the last sync:
    #
    #   only the local copy changed     -> upload
    #   only the server's copy changed  -> download
    #   both changed, or never synced   -> conflict: the copy with the later
    #                                      mtime / modified_at wins, the local
    #                                      one if they are equal
    #
    # Nothing is ever deleted on either side: a file missing on one side is
    # copied back to it, like push and pull would. Keys pull would skip are
    # skipped with the same warnings.
    #
    # A file that fails doesn't stop the others: its state stays as it was,
    # and the failures are reported together at the end, by raising
    # PartialFailure. A conflict whose transfer fails still counts as a conflict.
    class Sync
      Result = Data.define(:uploaded, :downloaded, :unchanged, :conflicts, :failed)

      def initialize(local_dir, remote, server:, out: $stdout, err: $stderr)
        @local_dir = local_dir
        @remote = remote
        @server = server
        @out = out
        @err = err
      end

      def run
        @local_dir.real_root # fail before contacting the server
        state = SyncState.new(@local_dir, @server, on_warning: ->(message) { @err.puts "syncbox: #{message}" })
        failures = Failures.new
        entries = @local_dir.entries(on_error: ->(error) { failures.add(error.message) }).to_h { |entry| [entry.key, entry] }
        blobs = @remote.list.to_h { |blob| [blob["key"], blob] }

        @counts = Result.members.to_h { |member| [member, 0] }
        begin
          (entries.keys | blobs.keys | state.keys).sort.each do |key|
            # What the walk couldn't read may exist locally: copying the
            # server's blob over it, or forgetting its state, could lose it.
            next if @local_dir.unreadable?(key)

            failures.guard { sync_key(key, entries[key], blobs[key], state) }
          end
        ensure
          # Records what has been synced, even if interrupted part way.
          failures.guard { state.save }
        end
        @counts[:failed] = failures.size

        result = Result.new(**@counts)
        @out.puts "sync: #{result.uploaded} uploaded, #{result.downloaded} downloaded, " \
                  "#{result.unchanged} unchanged, #{result.conflicts} conflict#{'s' unless result.conflicts == 1}" \
                  "#{failures.summary}"
        failures.raise_if_any("sync")
        result
      end

      private

      def sync_key(key, entry, blob, state)
        if entry && blob
          sha256 = LocalDir.sha256(entry)
          if sha256 == blob["sha256"]
            state[key] = sha256
            @counts[:unchanged] += 1
          elsif state[key] == sha256
            download(key, state)
          elsif state[key] == blob["sha256"]
            upload(entry, state)
          else
            resolve_conflict(entry, blob, state)
          end
        elsif entry
          upload(entry, state)
        elsif blob
          download(key, state)
        else
          state.delete(key) # gone from both sides
        end
      end

      # Both sides changed since the last sync (or were never synced): the
      # later modification wins, the local copy on a tie.
      def resolve_conflict(entry, blob, state)
        local_mtime, server_mtime = comparable_times(entry, blob)
        winner = if server_mtime > local_mtime
                   "the server's copy is newer"
                 elsif server_mtime < local_mtime
                   "the local copy is newer"
                 else
                   "both were modified at the same time, keeping the local copy"
                 end
        how = state[entry.key] ? "changed on both sides since the last sync" : "differs on both sides, never synced"
        @out.puts "conflict #{entry.key}: #{how}; #{winner}"
        @counts[:conflicts] += 1
        server_mtime > local_mtime ? download(entry.key, state) : upload(entry, state)
      end

      # The local file's mtime and the blob's modified_at, both cut to the
      # precision the server reports (the local one has nanoseconds), so that
      # times the server can't tell apart count as equal.
      def comparable_times(entry, blob)
        text = blob["modified_at"]
        server_mtime = Time.iso8601(text)
        digits = [text[/T\d\d:\d\d:\d\d\.(\d+)/, 1].to_s.size, 9].min
        [LocalDir.mtime(entry).floor(digits), server_mtime.floor(digits)]
      rescue ArgumentError, TypeError
        raise Error, "unexpected response from server to GET /blobs: invalid modified_at for #{entry.key}"
      end

      def upload(entry, state)
        answer = Push.upload(@remote, entry)
        # What the server stored is what both sides now have, even if the
        # local file changed while it was being sent.
        stored = answer["sha256"]
        state[entry.key] = stored.is_a?(String) && SyncState::SHA256_PATTERN.match?(stored) ? stored : LocalDir.sha256(entry)
        @counts[:uploaded] += 1
        @out.puts "uploaded #{entry.key}"
      end

      def download(key, state)
        target = @local_dir.target(key)
        return unless target # skipped with a warning

        digest = Digest::SHA256.new
        @local_dir.write(target) do |file|
          @remote.get(key) do |chunk|
            digest << chunk
            file.write(chunk)
          end
        end
        state[key] = digest.hexdigest
        @counts[:downloaded] += 1
        @out.puts "downloaded #{key}"
      end
    end
  end
end
