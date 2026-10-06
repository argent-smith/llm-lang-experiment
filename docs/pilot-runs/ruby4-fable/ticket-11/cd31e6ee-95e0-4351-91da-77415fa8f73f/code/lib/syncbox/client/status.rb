# frozen_string_literal: true

module Syncbox
  module Client
    # `syncbox status <dir>`: the dry run. Scans the directory, fetches the
    # server's listing once, compares the two by key and SHA-256 and prints
    # what push and pull would do — without doing any of it. Nothing under
    # <dir> is created, modified or removed, and the only request sent is
    # GET /blobs (no PUT, DELETE or even GET /blobs/{key}: the listing already
    # carries every hash the comparison needs). The exit status is 0 whenever
    # the comparison itself succeeded; differences are the output, not an
    # error.
    #
    # Every key ends up in exactly one group:
    #
    #   upload    only local — push would upload it
    #   download  only on the server — pull would download it
    #   differs   on both sides with different content — push would upload
    #             the local version, pull would download the server's; which
    #             one sync picks is decided by sync's conflict rule, not
    #             here
    #   unchanged identical on both sides — neither would touch it (counted,
    #             not listed)
    #
    # A download that pull would refuse (a directory or symlink where the
    # file would go, a key that could leave the directory) is still listed
    # as a download, with a note saying why pull would fail on it.
    #
    # A local entry that cannot be scanned (an unreadable file or directory,
    # a name that is not valid UTF-8) cannot be compared: it is reported as a
    # failure (see Failures), the rest of the comparison still happens, and
    # the Runner exits non-zero because the report is incomplete.
    class Status
      Entry = Struct.new(:key, :local, :remote, :note, keyword_init: true)

      Report = Struct.new(:uploads, :downloads, :differing, :unchanged, :failed, keyword_init: true) do
        def in_sync?
          uploads.empty? && downloads.empty? && differing.empty?
        end

        def to_s
          if in_sync? && failed.zero?
            "status: in sync, #{unchanged} file(s) identical on both sides (dry run: nothing was changed)"
          else
            counts = "#{uploads.size} to upload, #{downloads.size} to download, " \
                     "#{differing.size} differ#{differing.size == 1 ? 's' : ''} on both sides, #{unchanged} unchanged"
            counts += ", #{failed} not compared" if failed.positive?
            "status: #{counts} (dry run: nothing was changed)"
          end
        end
      end

      def initialize(dir:, api:, out: $stdout, err: $stderr)
        @dir = dir
        @api = api
        @out = out
        @err = err
      end

      def call
        tree = LocalTree.new(@dir)
        failures = Failures.new(err: @err)
        local = tree.scan(on_failure: failures.method(:record)) { |warning| @err.puts "syncbox: warning: #{warning}" }
                    .to_h { |f| [f.key, f] }
        # A key that could not be scanned (or lies under a directory that
        # could not be listed) is not known to be missing locally: it is left
        # out of the comparison, having been reported already.
        unscanned = failures.entries.map(&:key)
        remote = @api.list.to_h { |blob| [blob.key, blob] }
                     .reject { |key, _| unscanned.any? { |u| key == u || key.start_with?("#{u}/") } }

        report = compare(tree, local, remote)
        report.failed = failures.size
        print_report(report)
        failures.report("status", total: local.size + failures.size)
        report
      ensure
        @api.close
      end

      private

      def compare(tree, local, remote)
        report = Report.new(uploads: [], downloads: [], differing: [], unchanged: 0, failed: 0)

        local.each_value do |file|
          blob = remote[file.key]
          if blob.nil?
            report.uploads << Entry.new(key: file.key, local: file)
          elsif blob.sha256 == file.sha256
            report.unchanged += 1
          else
            report.differing << Entry.new(key: file.key, local: file, remote: blob)
          end
        end

        remote.each_value do |blob|
          next if local.key?(blob.key)

          report.downloads << Entry.new(key: blob.key, remote: blob, note: download_obstacle(tree, blob.key))
        end

        [report.uploads, report.downloads, report.differing].each { |group| group.sort_by!(&:key) }
        report
      end

      # The scan saw no regular file under this key, so pull would try to
      # write one: find out whether it could. Returns nil if the way is clear
      # or pull's complaint otherwise (without the key, which the line already
      # shows). Read-only: a lookup only stats.
      def download_obstacle(tree, key)
        tree.lookup(key)
        nil
      rescue LocalTree::Error => e
        e.message.delete_prefix("#{key}: ")
      end

      def print_report(report)
        report.uploads.each do |entry|
          line("upload", entry.key, "missing on server, #{bytes(entry.local.size)}")
        end
        report.downloads.each do |entry|
          detail = "missing locally, #{bytes(entry.remote.size)}"
          detail += "; pull would fail: #{entry.note}" if entry.note
          line("download", entry.key, detail)
        end
        report.differing.each do |entry|
          line("differs", entry.key,
               "local #{bytes(entry.local.size)}, server #{bytes(entry.remote.size)}; " \
               "push would upload, pull would download")
        end
        @out.puts report
      end

      def line(direction, key, detail)
        @out.puts format("%-8s  %s  (%s)", direction, key, detail)
      end

      def bytes(size)
        size.nil? ? "size unknown" : "#{size} bytes"
      end
    end
  end
end
