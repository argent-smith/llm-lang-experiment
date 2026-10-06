# frozen_string_literal: true

module Syncbox
  # CLI client component of Syncbox: talks to the server's HTTP API (see
  # syncbox-openapi.yaml) and reconciles a local directory against it.
  module Client
    VERSION = "0.1.0"

    # Base class of every error the client reports to the user (as opposed
    # to a bug): the Runner turns one into a message on stderr and a
    # non-zero exit status, and Failures treats one raised while handling a
    # single file as that file's failure rather than the run's.
    class Error < StandardError; end

    # Entry point used by bin/syncbox. Returns the process exit code.
    def self.run(argv, env: ENV, out: $stdout, err: $stderr)
      Runner.new(argv, env: env, out: out, err: err).run
    end
  end
end

require_relative "client/options"
require_relative "client/api"
require_relative "client/local_tree"
require_relative "client/transfer"
require_relative "client/failures"
require_relative "client/sync_state"
require_relative "client/push"
require_relative "client/pull"
require_relative "client/status"
require_relative "client/sync"
require_relative "client/runner"
