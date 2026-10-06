# frozen_string_literal: true

module Syncbox
  module Client
    # What a command failed to do with the files it handles. A file that fails
    # (a local read or write error, a request the server refuses or a
    # connection that breaks in the middle of one) does not stop the others:
    # its error is recorded and the command goes on, then reports every
    # failure at the end and exits non-zero ("Exit codes and errors" in
    # SYNCBOX-SPEC.md). Only an unreachable server (Remote::Unreachable) stops
    # the transfers: the rest would fail the same way, each after a timeout.
    class Failures
      # Raised by #check! when anything failed. +failures+ are the messages,
      # one per file, each naming its file.
      class Incomplete < Error
        attr_reader :failures

        def initialize(message, failures)
          super(message)
          @failures = failures
        end
      end

      def initialize(command)
        @command = command
        # {key => message}
        @failed = {}
        @not_attempted = 0
      end

      # Runs the block for the file +key+ and returns whether it succeeded.
      # An Error the block raises is recorded as the file's failure;
      # Remote::Unreachable is recorded and raised again.
      def attempt(key)
        yield
        true
      rescue Error => e
        @failed[key] = e.message
        raise if e.is_a?(Remote::Unreachable)

        false
      end

      # Attempts the block for each of +items+ (which respond to #key) in
      # turn, and gives the rest up if the server turns out unreachable.
      def each(items)
        items.each_with_index do |item, i|
          attempt(item.key) { yield item }
        rescue Remote::Unreachable
          @not_attempted = items.size - i - 1
          break
        end
      end

      # Whether the failure of +key+, or of a directory it lies in, has been
      # recorded.
      def include?(key)
        @failed.each_key.any? { |failed| key == failed || key.start_with?("#{failed}/") }
      end

      def empty?
        @failed.empty?
      end

      # To be appended to the command's summary line: "" if nothing failed.
      def summary
        counts = []
        counts << "#{@failed.size} failed" unless @failed.empty?
        counts << "#{@not_attempted} not attempted" if @not_attempted.positive?
        counts.map { |count| ", #{count}" }.join
      end

      # Raises Incomplete if anything failed.
      def check!
        return if @failed.empty?

        message = "#{@command} incomplete: #{@failed.size} failed"
        message += ", #{@not_attempted} not attempted (server unreachable)" if @not_attempted.positive?
        raise Incomplete.new(message, @failed.values)
      end
    end
  end
end
