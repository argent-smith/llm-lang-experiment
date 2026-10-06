# frozen_string_literal: true

require "time"

module Syncbox
  module Client
    # `syncbox sync <dir>`: push and pull in one pass, plus a conflict rule.
    # Scans the directory, fetches the server's listing once and walks the
    # union of keys; for each key the two sides and the last known common
    # version (SyncState, kept in <dir>/.syncbox/state.json) decide what
    # happens:
    #
    #   identical on both sides         nothing (the common version is noted)
    #   only local                      upload   (as push would)
    #   only on the server              download (as pull would)
    #   differs, server == last common  only the local side changed: upload
    #   differs, local  == last common  only the server changed: download
    #   differs, both moved away from   conflict — the spec's rule, verbatim:
    #   the last common version         the fresher of the server's
    #                                   modified_at and the local mtime wins;
    #                                   on a tie the local version wins
    #   differs, no common version      no run has seen this key in sync yet,
    #   known (first run)               so neither side can be told to be the
    #                                   unchanged one; the same mtime rule
    #                                   picks the side to copy
    #
    # "Differs" always means "the SHA-256 hashes differ"; mtimes are never
    # consulted when the content is the same. The server's modified_at is the
    # time the blob was stored (ISO 8601 UTC, millisecond precision), the
    # local mtime comes from the filesystem; they are compared as instants.
    #
    # sync never deletes anything, on either side: a file that disappeared
    # from one side since the last run is copied back from the other, exactly
    # like a file that is only on one side for any other reason. Deletion
    # propagation is not part of the spec.
    #
    # Transfers use Transfer (streamed PUT with sha256 check, staged GET with
    # rename into place). A key that fails — a local file that cannot be
    # read, a transfer the server answers with an unexpected status or that
    # breaks or does not hash to what was promised, something in the way of
    # a download, an unsafe key, a conflict whose modified_at cannot be
    # parsed — does not stop the sync: it is reported, its common state is
    # left as it was (so the next run tries it again) and the remaining keys
    # are still reconciled (see Failures). The summary then counts the
    # failures, the failed keys are listed on stderr and the Runner exits
    # non-zero. The state is saved on the way out — also when the run stops
    # because the server went away (Failures::ServerLost) or on an interrupt
    # — for the keys that were reconciled, so a rerun picks up where this
    # run stopped.
    class Sync
      class Error < Client::Error; end

      Summary = Struct.new(:uploaded, :downloaded, :unchanged, :conflicts, :failed, keyword_init: true) do
        def to_s
          counts = ["#{uploaded} uploaded", "#{downloaded} downloaded", "#{unchanged} unchanged"]
          counts << "#{failed} failed" if failed.positive?
          "sync done: #{counts.join(', ')}, #{conflicts} conflict(s) resolved"
        end
      end

      # +server+ is the server URL as a string; it keys the base state, so
      # one directory can be synced with more than one server.
      def initialize(dir:, api:, server:, out: $stdout, err: $stderr)
        @dir = dir
        @api = api
        @server = server.to_s
        @out = out
        @err = err
      end

      def call
        @tree = LocalTree.new(@dir)
        @tree.require_directory!
        @state = SyncState.load(@dir, server: @server)
        @failures = Failures.new(err: @err)
        local = @tree.scan(on_failure: @failures.method(:record)) { |warning| @err.puts "syncbox: warning: #{warning}" }
                     .to_h { |f| [f.key, f] }
        remote = @api.list.to_h { |blob| [blob.key, blob] }
        @transfer = Transfer.new(api: @api, out: @out, err: @err)
        @summary = Summary.new(uploaded: 0, downloaded: 0, unchanged: 0, conflicts: 0, failed: @failures.size)
        # A key that could not be scanned (or lies under a directory that
        # could not be listed) is not known to be missing locally — the
        # server's version must not be written over whatever is there. It has
        # been reported; it is left out of this run and keeps its state.
        unscanned = @failures.entries.map(&:key)
        unscanned_key = ->(key) { unscanned.any? { |u| key == u || key.start_with?("#{u}/") } }
        keys = (local.keys | remote.keys).sort.reject(&unscanned_key)
        total = keys.size + @failures.size

        begin
          # A key gone from both sides has no common version any more.
          @state.keys.each { |key| @state.forget(key) unless local.key?(key) || remote.key?(key) || unscanned_key.call(key) }

          keys.each_with_index do |key, index|
            @failures.attempt(key, remaining: keys.size - index - 1) { reconcile(key, local[key], remote[key]) }
          end

          @summary.failed = @failures.size
          @out.puts @summary
          @failures.report("sync", total: total)
        rescue Failures::ServerLost => e
          @failures.report("sync", total: total, not_attempted: e.not_attempted)
          raise
        ensure
          # $! is the exception on its way out of this method, if any.
          save_state(failing: !$!.nil?)
        end

        @summary
      ensure
        @api.close
      end

      private

      def reconcile(key, file, blob)
        base = @state[key]
        if file && blob
          if file.sha256 == blob.sha256
            @summary.unchanged += 1
            @state.record(key, file.sha256)
          elsif blob.sha256 == base
            upload(file, "changed locally")
          elsif file.sha256 == base
            download(blob, file, "changed on server")
          else
            resolve_conflict(file, blob, base)
          end
        elsif file
          upload(file, base ? "missing on server" : "new")
        else
          download(blob, nil, base ? "missing locally" : "new")
        end
      end

      # Both sides differ from each other and neither is the last common
      # version (or none is known): the fresher side wins, local on a tie.
      def resolve_conflict(file, blob, base)
        server_time = parse_modified_at(blob)
        what = base ? "conflict" : "differs on both sides"

        if server_time > file.mtime
          download(blob, file, "#{what}, server is newer")
        elsif server_time == file.mtime
          upload(file, "#{what}, same mtime, local wins")
        else
          upload(file, "#{what}, local is newer")
        end
        @summary.conflicts += 1 if base
      end

      def upload(file, reason)
        @transfer.upload(file, reason)
        @state.record(file.key, file.sha256)
        @summary.uploaded += 1
      end

      def download(blob, local, reason)
        @transfer.download(@tree, blob, local, reason)
        @state.record(blob.key, blob.sha256)
        @summary.downloaded += 1
      end

      def parse_modified_at(blob)
        Time.iso8601(blob.modified_at.to_s)
      rescue ArgumentError
        raise Error, "#{blob.key}: cannot resolve the conflict: the server's modified_at " \
                     "#{blob.modified_at.inspect} is not an ISO 8601 timestamp"
      end

      # Saves the state. While another error is already propagating, a
      # failure to save is only a warning, so the original error is the one
      # reported.
      def save_state(failing:)
        @state.save
      rescue SyncState::Error => e
        raise unless failing

        @err.puts "syncbox: warning: #{e.message}"
      end
    end
  end
end
