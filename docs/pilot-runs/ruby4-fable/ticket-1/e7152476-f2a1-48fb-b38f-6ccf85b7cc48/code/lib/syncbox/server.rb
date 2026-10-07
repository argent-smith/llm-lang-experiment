# frozen_string_literal: true

require_relative "server/config"
require_relative "server/app"
require_relative "server/runner"

module Syncbox
  # HTTP server component of Syncbox: a Rack application served by Puma,
  # configured from CLI flags / environment variables (see Config).
  module Server
    VERSION = "0.1.0"

    # Entry point used by bin/syncbox-server. Returns the process exit code.
    def self.run(argv, env: ENV, out: $stdout, err: $stderr)
      Runner.new(argv, env: env, out: out, err: err).run
    end
  end
end
