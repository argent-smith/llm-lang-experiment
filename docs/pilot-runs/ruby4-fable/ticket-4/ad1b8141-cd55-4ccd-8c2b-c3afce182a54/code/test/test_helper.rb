# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rack/test"
require "tmpdir"
require "syncbox/server"

module TestHelpers
  ROOT = File.expand_path("..", __dir__)

  def with_tmpdir(&block)
    Dir.mktmpdir("syncbox-test-", &block)
  end
end
