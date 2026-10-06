# frozen_string_literal: true

module Syncbox
  module Client
    # The spec's "partial failure" rule, shared by push, pull, sync and
    # status: when one file out of many fails, the others are still
    # processed, the failed ones are reported at the end and the exit status
    # is non-zero. One instance collects the failures of one run.
    #
    # #attempt runs the work for one key. An error that belongs to that key
    # alone — the server answered the request with an unexpected status
    # (HttpError, e.g. a 5xx), a transfer that did not hash to what was
    # promised, a local file that cannot be read or written, a key that
    # cannot be mapped to a path — is recorded with a line on stderr and the
    # run goes on. Anything else (a bug, an Interrupt) propagates.
    #
    # A network failure on a single request (Api::Unreachable) is a per-file
    # failure too: the connection may have been reset by a server restart or
    # a flaky link while the next request goes through. But when requests
    # for MAX_CONSECUTIVE_UNREACHABLE files in a row cannot reach the server,
    # the server is gone, not the file: trying the remaining files would only
    # pile up identical failures (and, against a black-holed address, wait
    # the connect timeout for each of them), so #attempt raises ServerLost
    # and the command stops, reporting what was done and what was not. Local
    # errors in between neither break nor extend the streak; an answer from
    # the server, even an error status, resets it.
    class Failures
      Entry = Struct.new(:key, :message, keyword_init: true)

      # Raised by #attempt when the server has stopped answering (see above).
      # +not_attempted+ is the number of keys the command had not reached.
      class ServerLost < Error
        attr_reader :last_error, :not_attempted

        def initialize(last_error, not_attempted:, streak:)
          @last_error = last_error
          @not_attempted = not_attempted
          super("server unreachable: #{last_error.message}; giving up after #{streak} consecutive requests failed " \
                "(#{not_attempted} file(s) not attempted — rerun once the server is back)")
        end
      end

      MAX_CONSECUTIVE_UNREACHABLE = 2

      attr_reader :entries

      def initialize(err: $stderr)
        @err = err
        @entries = []
        @unreachable_streak = 0
      end

      # Runs the block for +key+; +remaining+ is how many keys the command
      # still has to process after this one (for ServerLost's report). Returns
      # the block's value, or nil if it failed and the failure was recorded.
      def attempt(key, remaining: 0)
        result = yield
        @unreachable_streak = 0
        result
      rescue Api::Unreachable => e
        record(key, e.message)
        @unreachable_streak += 1
        raise ServerLost.new(e, not_attempted: remaining, streak: @unreachable_streak) if @unreachable_streak >= MAX_CONSECUTIVE_UNREACHABLE

        nil
      rescue Client::Error, SystemCallError => e
        # An Api or Transfer error means the server answered (with an
        # unexpected status, a body that did not match, or a response the
        # local disk could not take): it is reachable. A local error
        # (LocalTree, a sync rule, the OS) says nothing about the server.
        @unreachable_streak = 0 if e.is_a?(Api::Error) || e.is_a?(Transfer::Error)
        record(key, e.message)
        nil
      end

      # Records that +key+ failed and says so on stderr right away, so a long
      # run shows its failures as they happen; the list at the end (#report)
      # is the spec's summary of the same.
      def record(key, message)
        # A name that is not valid UTF-8 (so not a key) is shown escaped.
        key = key.inspect unless key.valid_encoding?
        message = message.delete_prefix("#{key}: ")
        @entries << Entry.new(key: key, message: message)
        @err.puts "syncbox: failed #{key}: #{message}"
      end

      def size
        @entries.size
      end

      def empty?
        @entries.empty?
      end

      def any?
        !empty?
      end

      # The end-of-run report on stderr: nothing if nothing failed, otherwise
      # a headline with the counts and one line per failed key, in the order
      # the failures happened. +total+ is the number of keys the command set
      # out to process; +not_attempted+ (ServerLost) the number it never
      # reached.
      def report(command, total:, not_attempted: 0)
        return if empty? && not_attempted.zero?

        headline = "#{command} #{not_attempted.positive? ? 'aborted' : 'incomplete'}: #{size} of #{total} file(s) failed"
        headline += ", #{not_attempted} not attempted" if not_attempted.positive?
        @err.puts "syncbox: #{headline}"
        @entries.each { |entry| @err.puts "syncbox:   #{entry.key}: #{entry.message}" }
      end
    end
  end
end
