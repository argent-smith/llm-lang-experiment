# frozen_string_literal: true

module Syncbox
  module Client
    # `syncbox push <dir>`: scans the directory, fetches the server's listing
    # once, and uploads every local file whose key is missing on the server or
    # whose SHA-256 differs from the server's. Files with identical content
    # are not re-sent. Blobs that exist only on the server are left alone.
    #
    # A file that fails — it cannot be read, the server answers its PUT with
    # an unexpected status, the request breaks, the hash the server stores is
    # not the one sent — does not stop the push: it is reported and the
    # remaining files are still uploaded (see Failures). The summary then
    # counts the failures, the failed files are listed on stderr and the
    # Runner exits non-zero. What stops the push is a problem with the whole
    # run: the directory is missing, the listing cannot be fetched, or the
    # server stops answering altogether (Failures::ServerLost).
    class Push
      # Raised when the server stored different bytes than were sent.
      Error = Transfer::Error

      Summary = Struct.new(:scanned, :uploaded, :unchanged, :failed, keyword_init: true) do
        def to_s
          counts = ["#{uploaded} uploaded", "#{unchanged} unchanged"]
          counts << "#{failed} failed" if failed.positive?
          "push done: #{counts.join(', ')}, #{scanned} file(s) scanned"
        end
      end

      def initialize(dir:, api:, out: $stdout, err: $stderr)
        @dir = dir
        @api = api
        @out = out
        @err = err
      end

      def call
        failures = Failures.new(err: @err)
        files = LocalTree.scan(@dir, on_failure: failures.method(:record)) { |warning| @err.puts "syncbox: warning: #{warning}" }
        total = files.size + failures.size
        remote = @api.list.to_h { |blob| [blob.key, blob] }
        transfer = Transfer.new(api: @api, out: @out, err: @err)

        summary = Summary.new(scanned: files.size, uploaded: 0, unchanged: 0, failed: failures.size)
        begin
          files.each_with_index do |file, index|
            existing = remote[file.key]
            if existing && existing.sha256 == file.sha256
              summary.unchanged += 1
              next
            end

            failures.attempt(file.key, remaining: files.size - index - 1) do
              transfer.upload(file, existing ? "changed" : "new")
              summary.uploaded += 1
            end
          end
        rescue Failures::ServerLost => e
          failures.report("push", total: total, not_attempted: e.not_attempted)
          raise
        end

        summary.failed = failures.size
        @out.puts summary
        failures.report("push", total: total)
        summary
      ensure
        @api.close
      end
    end
  end
end
