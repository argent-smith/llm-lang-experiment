# frozen_string_literal: true

module Syncbox
  # CLI client: compares a local directory with the server by SHA-256 and
  # transfers the difference.
  module Client
    # A failure the user should see as a one-line message (exit code 1).
    class Error < StandardError; end
  end
end

require_relative "client/config"
require_relative "client/local_tree"
require_relative "client/remote"
require_relative "client/push"
require_relative "client/pull"
require_relative "client/cli"
