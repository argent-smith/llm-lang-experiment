# frozen_string_literal: true

module Syncbox
  module Client
    # `syncbox push <dir>`: scans the directory, fetches the server's listing
    # once, and uploads every local file whose key is missing on the server or
    # whose SHA-256 differs from the server's. Files with identical content
    # are not re-sent. Blobs that exist only on the server are left alone.
    #
    # Failures stop the push at the first problem with a clear message
    # (continuing past per-file failures and reporting them is ticket 11).
    class Push
      # Raised when the server stored different bytes than were sent.
      Error = Transfer::Error

      Summary = Struct.new(:scanned, :uploaded, :unchanged, keyword_init: true) do
        def to_s
          "push done: #{uploaded} uploaded, #{unchanged} unchanged, #{scanned} file(s) scanned"
        end
      end

      def initialize(dir:, api:, out: $stdout, err: $stderr)
        @dir = dir
        @api = api
        @out = out
        @err = err
      end

      def call
        files = LocalTree.scan(@dir) { |warning| @err.puts "syncbox: warning: #{warning}" }
        remote = @api.list.to_h { |blob| [blob.key, blob] }
        transfer = Transfer.new(api: @api, out: @out, err: @err)

        summary = Summary.new(scanned: files.size, uploaded: 0, unchanged: 0)
        files.each do |file|
          existing = remote[file.key]
          if existing && existing.sha256 == file.sha256
            summary.unchanged += 1
            next
          end

          transfer.upload(file, existing ? "changed" : "new")
          summary.uploaded += 1
        end

        @out.puts summary
        summary
      ensure
        @api.close
      end
    end
  end
end
