# frozen_string_literal: true

module Syncbox
  module Client
    # syncbox push: uploads every local file that the server lacks or holds
    # with different contents (by SHA-256). Files identical to the server's
    # version are not sent again; blobs that exist only on the server are
    # left alone.
    #
    # A file that fails (it can't be read, the server rejects it, the
    # connection fails) doesn't stop the others: the failures are reported
    # together at the end, by raising PartialFailure.
    class Push
      Result = Data.define(:uploaded, :unchanged, :failed)

      def initialize(local_dir, remote, out: $stdout)
        @local_dir = local_dir
        @remote = remote
        @out = out
      end

      def run
        failures = Failures.new
        entries = @local_dir.entries(on_error: ->(error) { failures.add(error.message) })
        remote_sha256 = @remote.list.to_h { |blob| [blob["key"], blob["sha256"]] }

        uploaded = 0
        unchanged = 0
        entries.each do |entry|
          failures.guard do
            if remote_sha256[entry.key] == LocalDir.sha256(entry)
              unchanged += 1
            else
              self.class.upload(@remote, entry)
              uploaded += 1
              @out.puts "uploaded #{entry.key}"
            end
          end
        end

        result = Result.new(uploaded: uploaded, unchanged: unchanged, failed: failures.size)
        @out.puts "push: #{result.uploaded} uploaded, #{result.unchanged} unchanged#{failures.summary}"
        failures.raise_if_any("push")
        result
      end

      # PUTs an entry's file under its key; returns the server's answer.
      def self.upload(remote, entry)
        file = begin
          File.open(entry.path, File::RDONLY | File::NOFOLLOW | File::BINARY)
        rescue SystemCallError => e
          raise Error, "cannot read #{entry.key}: #{LocalDir.reason(e)}"
        end
        begin
          remote.put(entry.key, file, file.size)
        ensure
          file.close
        end
      end
    end
  end
end
