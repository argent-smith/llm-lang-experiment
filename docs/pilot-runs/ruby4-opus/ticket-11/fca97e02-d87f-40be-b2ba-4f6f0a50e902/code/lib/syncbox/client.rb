# frozen_string_literal: true

module Syncbox
  # CLI client: compares a local directory with the server by SHA-256 and
  # transfers the difference.
  module Client
    # A failure the user should see as a one-line message (exit code 1).
    class Error < StandardError; end

    # Top-level entry of a synced directory where sync keeps its state (see
    # SyncState). It is the client's own, not the user's: no command uploads
    # it, and blobs whose keys fall inside it are never downloaded.
    STATE_DIR = ".syncbox"

    def self.reserved_key?(key)
      key == STATE_DIR || key.start_with?("#{STATE_DIR}/")
    end
  end
end

require_relative "client/config"
require_relative "client/local_tree"
require_relative "client/remote"
require_relative "client/failures"
require_relative "client/push"
require_relative "client/pull"
require_relative "client/status"
require_relative "client/sync_state"
require_relative "client/sync"
require_relative "client/cli"
