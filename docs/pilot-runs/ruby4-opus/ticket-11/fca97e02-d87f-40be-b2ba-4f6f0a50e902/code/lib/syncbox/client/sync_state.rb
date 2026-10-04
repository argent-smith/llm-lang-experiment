# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Syncbox
  module Client
    # What sync last left identical on both sides: for each server it synced
    # the directory with, the SHA-256 of every file that the directory and the
    # server then held with the same content. Kept in
    # <dir>/.syncbox/state.json:
    #
    #   {"version": 1, "servers": {"http://127.0.0.1:8080": {"docs/a.txt": "<sha256>"}}}
    #
    # Servers are told apart by URL: what is common with one says nothing
    # about another.
    class SyncState
      VERSION = 1
      FILE = "state.json"
      SHA256 = /\A[0-9a-f]{64}\z/
      NOT_A_DIRECTORY = "cannot keep sync state: #{STATE_DIR} is not a directory".freeze

      # Reads the state of +dir+; a directory never synced has an empty one.
      # Raises Error if the state cannot be read or makes no sense, or if
      # something other than a directory is where it is kept.
      def self.load(dir)
        state_dir = File.join(dir, STATE_DIR)
        check_state_dir(state_dir)
        json = File.open(File.join(state_dir, FILE), File::RDONLY | File::NOFOLLOW, &:read)
        new(dir, parse(json) || raise(Error, "sync state #{STATE_DIR}/#{FILE} is corrupt; remove it to start afresh"))
      rescue Errno::ENOENT
        new(dir, {})
      rescue SystemCallError => e
        raise Error, "cannot read sync state #{STATE_DIR}/#{FILE}: #{e.class.new.message}"
      end

      # {server => {key => sha256}}, or nil if +json+ is not a state.
      def self.parse(json)
        state = JSON.parse(json)
        servers = state["servers"] if state.is_a?(Hash) && state["version"] == VERSION
        valid = servers.is_a?(Hash) && servers.each_value.all? do |files|
          files.is_a?(Hash) && files.all? { |key, sha256| key.is_a?(String) && sha256.is_a?(String) && sha256.match?(SHA256) }
        end
        servers if valid
      rescue JSON::ParserError
        nil
      end
      def self.check_state_dir(path)
        raise Error, NOT_A_DIRECTORY unless File.lstat(path).directory?
      rescue Errno::ENOENT
        nil
      end
      private_class_method :parse, :check_state_dir

      def initialize(dir, servers)
        @dir = dir
        @servers = servers
      end

      # {key => sha256} last common with +server+.
      def common(server)
        @servers.fetch(server, {})
      end

      # Records +files+ ({key => sha256}) as common with +server+ and writes
      # the state back: to a temporary file in the state directory first,
      # then renamed over the old state, so an interrupted write leaves the
      # old state intact. Does nothing if +files+ are what was common already.
      def update(server, files)
        return if common(server) == files

        @servers = @servers.merge(server => files)
        state_dir = File.join(@dir, STATE_DIR)
        make_state_dir(state_dir)
        tmp = File.join(state_dir, "#{FILE}.#{SecureRandom.hex(8)}.tmp")
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL) do |file|
          file.write(JSON.generate({ "version" => VERSION, "servers" => @servers }))
          file.fsync
        end
        File.rename(tmp, File.join(state_dir, FILE))
      rescue SystemCallError => e
        raise Error, "cannot write sync state #{STATE_DIR}/#{FILE}: #{e.class.new.message}"
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      private

      def make_state_dir(path)
        Dir.mkdir(path)
      rescue Errno::EEXIST
        raise Error, NOT_A_DIRECTORY unless File.lstat(path).directory?
      end
    end
  end
end
