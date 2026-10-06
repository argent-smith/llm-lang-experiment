# frozen_string_literal: true

require "json"
require "securerandom"

module Syncbox
  module Client
    # The "last known common state" that sync's conflict rule is defined
    # against: for every key that was identical on both sides at the end of a
    # sync run, the SHA-256 of that common version. On the next run a side
    # whose hash still equals the recorded one has not changed, so a
    # difference between the sides can be attributed to the other side alone;
    # only when both sides have moved away from it is there a real conflict.
    #
    # Kept in <dir>/.syncbox/state.json, so it travels with the directory and
    # survives between runs even though the client itself runs in a throwaway
    # container that sees nothing but <dir>. The entry is reserved: LocalTree
    # neither uploads it nor lets a download write into it. Entries are kept
    # per server URL, so one directory can be synced with several servers
    # without one sync confusing the other's base state.
    #
    #   {
    #     "version": 1,
    #     "servers": {
    #       "http://127.0.0.1:8080": {
    #         "files": { "docs/readme.txt": "<sha256 hex>", ... }
    #       }
    #     }
    #   }
    #
    # #save rewrites the file atomically (staging file + rename), so a run
    # interrupted while saving leaves the previous state, never a torn file.
    class SyncState
      class Error < Client::Error; end

      DIR = LocalTree::STATE_DIR
      FILE = "state.json"
      VERSION = 1
      SHA256_HEX = /\A[0-9a-f]{64}\z/

      attr_reader :path, :server

      # Loads the state for +server+ (a URL string) kept under +dir+; a
      # missing file is an empty state, anything unreadable or malformed is an
      # Error naming the file (deleting it resets the base state; the next
      # sync then falls back to the no-common-state rules).
      def self.load(dir, server:)
        path = File.join(File.expand_path(dir), DIR, FILE)
        document = read_document(path)
        files = document.dig("servers", server, "files") || {}
        unless files.is_a?(Hash) && files.all? { |k, v| k.is_a?(String) && v.is_a?(String) && v.match?(SHA256_HEX) }
          raise Error, "#{path}: malformed entry for server #{server}; delete the file to reset the sync state"
        end

        new(path, server, document, files.dup)
      end

      def self.read_document(path)
        raw = File.read(path, mode: "rb")
        document = JSON.parse(raw)
        raise Error, "#{path}: expected a JSON object; delete the file to reset the sync state" unless document.is_a?(Hash)
        unless document["version"] == VERSION
          raise Error, "#{path}: unsupported sync state version #{document['version'].inspect} (this client writes " \
                       "version #{VERSION}); delete the file to reset the sync state"
        end
        unless document["servers"].nil? || document["servers"].is_a?(Hash)
          raise Error, "#{path}: \"servers\" must be an object; delete the file to reset the sync state"
        end

        document
      rescue Errno::ENOENT
        { "version" => VERSION, "servers" => {} }
      rescue JSON::ParserError => e
        raise Error, "#{path}: not valid JSON (#{e.message[0, 100]}); delete the file to reset the sync state"
      rescue SystemCallError => e
        raise Error, "cannot read sync state #{path}: #{e.message}"
      end
      private_class_method :read_document

      def initialize(path, server, document, files)
        @path = path
        @server = server
        @document = document
        @files = files
        @dirty = false
      end

      # SHA-256 of the last common version of +key+, or nil if none is known.
      def [](key)
        @files[key]
      end

      def key?(key)
        @files.key?(key)
      end

      def keys
        @files.keys
      end

      def empty?
        @files.empty?
      end

      # Records +sha256+ as the common version of +key+.
      def record(key, sha256)
        return if @files[key] == sha256

        @files[key] = sha256
        @dirty = true
      end

      # Forgets +key+ (it is gone from both sides).
      def forget(key)
        @dirty = true if @files.delete(key)
      end

      def dirty?
        @dirty
      end

      # Writes the state back if anything changed. Other servers' entries in
      # the file are preserved as they were read.
      def save
        return unless @dirty

        servers = (@document["servers"] || {}).dup
        servers[@server] = { "files" => @files.sort.to_h }
        document = { "version" => VERSION, "servers" => servers }

        dir = File.dirname(@path)
        staging = File.join(dir, ".#{FILE}.#{SecureRandom.hex(8)}.tmp")
        begin
          Dir.mkdir(dir) unless File.directory?(dir)
          File.open(staging, File::WRONLY | File::CREAT | File::EXCL, 0o644, binmode: true) do |f|
            f.write(JSON.pretty_generate(document), "\n")
            f.flush
            f.fsync
          end
          File.rename(staging, @path)
        rescue SystemCallError => e
          begin
            File.unlink(staging)
          rescue SystemCallError
            nil
          end
          raise Error, "cannot write sync state #{@path}: #{e.message}"
        end
        @dirty = false
        @path
      end
    end
  end
end
