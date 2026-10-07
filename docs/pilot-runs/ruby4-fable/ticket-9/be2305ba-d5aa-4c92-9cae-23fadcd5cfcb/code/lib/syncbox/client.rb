# frozen_string_literal: true

require_relative "client/options"
require_relative "client/api"
require_relative "client/local_tree"
require_relative "client/push"
require_relative "client/pull"
require_relative "client/status"
require_relative "client/runner"

module Syncbox
  # CLI client component of Syncbox: talks to the server's HTTP API (see
  # syncbox-openapi.yaml) and reconciles a local directory against it.
  module Client
    VERSION = "0.1.0"

    # Entry point used by bin/syncbox. Returns the process exit code.
    def self.run(argv, env: ENV, out: $stdout, err: $stderr)
      Runner.new(argv, env: env, out: out, err: err).run
    end
  end
end
