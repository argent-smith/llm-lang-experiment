# frozen_string_literal: true

module Syncbox
  module Client
    # The command line itself is wrong (exit status 2).
    class UsageError < StandardError; end

    # The command could not be carried out (exit status 1).
    class Error < StandardError; end

    # Some files failed while the others were processed (exit status 1). The
    # message lists every failure, one per line.
    class PartialFailure < Error
      attr_reader :failures

      def initialize(command, failures)
        @failures = failures
        super("#{command} failed for #{failures.size} file#{'s' unless failures.size == 1}:\n" +
              failures.map { |message| "  #{message}" }.join("\n"))
      end
    end

    # Collects the failures of single files, so that a command can go on with
    # the other files and report them all at the end. Each message names the
    # file it is about.
    class Failures
      def initialize
        @messages = []
      end

      def add(message)
        @messages << message
      end

      # Runs the block; an Error it raises is recorded instead of propagating.
      # Returns whether the block succeeded.
      def guard
        yield
        true
      rescue Error => e
        add(e.message)
        false
      end

      def size
        @messages.size
      end

      def empty?
        @messages.empty?
      end

      # The end of a summary line: how many files failed, if any did.
      def summary
        empty? ? "" : ", #{size} failed"
      end

      # Raises PartialFailure for command if anything failed.
      def raise_if_any(command)
        raise PartialFailure.new(command, @messages.dup) unless empty?
      end
    end
  end
end
