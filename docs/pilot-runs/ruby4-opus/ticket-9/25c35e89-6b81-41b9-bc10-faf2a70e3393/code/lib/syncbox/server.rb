# frozen_string_literal: true

module Syncbox
  # HTTP server: blob storage on top of a local directory.
  module Server
  end
end

require_relative "server/config"
require_relative "server/storage"
require_relative "server/app"
require_relative "server/cli"
