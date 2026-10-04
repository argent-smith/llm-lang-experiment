# frozen_string_literal: true

module Syncbox
  module Client
    # The command line itself is wrong (exit status 2).
    class UsageError < StandardError; end

    # The command could not be carried out (exit status 1).
    class Error < StandardError; end
  end
end
