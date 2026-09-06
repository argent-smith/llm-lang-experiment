require "json"
require "fileutils"
require "pathname"
require "securerandom"

module Syncbox
  # Persists sync's "last known common state": for each key, the SHA-256
  # that was equal on both sides as of the last successful sync run. Each
  # `run-client` invocation is a fresh, throwaway container, so the only
  # thing that survives between runs is the mounted <dir> itself - hence
  # the state lives there too, under a directory name reserved from
  # ordinary push/pull/sync/status traffic (see .reserved?).
  module Manifest
    DIR = ".syncbox"
    FILE_NAME = "manifest.json"

    module_function

    def reserved?(key)
      key == DIR || key.start_with?("#{DIR}/")
    end

    def load(base)
      path = state_path(base)
      return {} unless path.file?

      JSON.parse(path.read)
    rescue JSON::ParserError
      {}
    end

    def save(base, state)
      dir = base + DIR
      FileUtils.mkdir_p(dir)
      tmp = dir + "#{FILE_NAME}.#{SecureRandom.hex(8)}.tmp"
      tmp.write(JSON.generate(state))
      File.rename(tmp, state_path(base))
    end

    def state_path(base)
      base + DIR + FILE_NAME
    end
  end
end
