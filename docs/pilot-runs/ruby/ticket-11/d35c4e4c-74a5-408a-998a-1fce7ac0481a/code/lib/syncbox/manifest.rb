require "json"
require_relative "local_files"

module Syncbox
  # Persists sync's "last known common state" between separate `syncbox
  # sync` invocations: for each key, the SHA-256 both sides shared as of
  # the last successful sync. That tracking mechanism is explicitly left
  # to the implementation by SYNCBOX-SPEC.md ("Что не специфицируется
  # намеренно"); this is a plain JSON file stored under
  # LocalFiles::MANIFEST_FILENAME inside the synced directory, since a
  # bind-mounted <dir> is the only location the `syncbox` CLI is
  # guaranteed durable, writable access to between separate container
  # runs (see docker-compose.yml: the client container mounts only
  # <dir>, nothing else survives between invocations).
  class Manifest
    def self.load(dir)
      path = path_for(dir)
      base_shas = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      new(dir, base_shas)
    rescue JSON::ParserError
      new(dir, {})
    end

    def self.path_for(dir)
      File.join(File.expand_path(dir), LocalFiles::MANIFEST_FILENAME)
    end

    def initialize(dir, base_shas)
      @dir = dir
      @base_shas = base_shas
    end

    def [](key)
      @base_shas[key]
    end

    def []=(key, sha256)
      @base_shas[key] = sha256
    end

    def save
      File.write(self.class.path_for(@dir), JSON.generate(@base_shas))
    end
  end
end
