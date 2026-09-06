#!/usr/bin/env ruby

require "fileutils"
require_relative "config"
require_relative "app"

begin
  config = Syncbox::Config.parse(ARGV)
rescue Syncbox::Config::Error => e
  warn "syncbox-server: #{e.message}"
  exit 1
end

FileUtils.mkdir_p(config.data_dir)

Syncbox::App.set(:data_dir, config.data_dir)
Syncbox::App.set(:port, config.port)
Syncbox::App.set(:bind, "0.0.0.0")
Syncbox::App.set(:server, :puma)
Syncbox::App.set(:dump_errors, true)
Syncbox::App.set(:raise_errors, false)

Syncbox::App.run!
