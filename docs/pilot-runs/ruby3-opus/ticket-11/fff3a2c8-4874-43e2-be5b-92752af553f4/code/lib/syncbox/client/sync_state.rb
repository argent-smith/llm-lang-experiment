# frozen_string_literal: true

require "json"

module Syncbox
  module Client
    # The last state sync knows the directory and a server to have had in
    # common: for each key, the SHA-256 that the local file and the server's
    # blob shared when sync last found or made them equal. Kept per server in
    # a JSON file at the root of the directory (LocalDir::STATE_FILE_NAME),
    # which push, pull, status and sync never treat as content:
    #
    #   {"version": 1, "servers": {"http://host:8080": {"docs/a.txt": "<sha256>"}}}
    #
    # The state lives and dies with the directory: a fresh directory, or one
    # synced with this server for the first time, has none.
    class SyncState
      VERSION = 1
      SHA256_PATTERN = /\A[0-9a-f]{64}\z/

      # How a server is told apart from others: its base URL, without what
      # doesn't change which server and path prefix are meant.
      def self.server_id(url)
        "#{url.scheme}://#{url.host.downcase}:#{url.port}#{url.path.chomp('/')}"
      end

      # The state of local_dir with the server at url (a URI::HTTP). A missing
      # state file means no state yet; one that can't be read or makes no
      # sense is reported via on_warning and treated the same way.
      def initialize(local_dir, url, on_warning: ->(_message) {})
        @local_dir = local_dir
        @server = self.class.server_id(url)
        @on_warning = on_warning
        @servers = read
        @saved = @servers.fetch(@server, {})
        @files = @saved.dup
      end

      # The SHA-256 key last had on both sides, or nil if that isn't known.
      def [](key)
        @files[key]
      end

      def []=(key, sha256)
        @files[key] = sha256
      end

      def delete(key)
        @files.delete(key)
      end

      def keys
        @files.keys
      end

      # Writes the state file if the state has changed, staged and renamed
      # into place like a pulled file. A directory without any state yet gets
      # no state file.
      def save
        return if @files == @saved

        servers = @servers.merge(@server => @files.sort.to_h)
        servers.delete(@server) if @files.empty?
        json = JSON.pretty_generate("version" => VERSION, "servers" => servers.sort.to_h)
        @local_dir.write(LocalDir::Target.new(key: LocalDir::STATE_FILE_NAME, path: path, stat: nil)) do |file|
          file.write(json, "\n")
        end
        @servers = servers
        @saved = @files.dup
      end

      private

      def path
        File.join(@local_dir.real_root, LocalDir::STATE_FILE_NAME.b)
      end

      # {server id => {key => sha256}} from the state file.
      def read
        json = File.open(path, File::RDONLY | File::NOFOLLOW | File::BINARY, &:read)
        data = JSON.parse(json.force_encoding(Encoding::UTF_8))
        servers = data["servers"] if data.is_a?(Hash) && data["version"] == VERSION
        return servers if valid?(servers)

        ignore("not a syncbox #{VERSION} state file")
      rescue Errno::ENOENT
        {}
      rescue SystemCallError, IOError => e
        ignore(LocalDir.reason(e))
      rescue JSON::ParserError, EncodingError
        ignore("invalid JSON")
      end

      def valid?(servers)
        servers.is_a?(Hash) && servers.each_value.all? do |files|
          files.is_a?(Hash) && files.all? do |key, sha256|
            key.valid_encoding? && sha256.is_a?(String) && SHA256_PATTERN.match?(sha256)
          end
        end
      end

      def ignore(reason)
        @on_warning.call("ignoring sync state #{LocalDir::STATE_FILE_NAME}: #{reason}")
        {}
      end
    end
  end
end
