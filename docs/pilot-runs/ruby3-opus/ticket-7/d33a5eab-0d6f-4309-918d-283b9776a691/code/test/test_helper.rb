# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "syncbox/server"
require "syncbox/client"
require "puma"
require "puma/log_writer"

# A Rack app served over real HTTP on 127.0.0.1 from a background thread.
class TestHTTPServer
  attr_reader :port

  def self.open(app)
    server = new(app)
    yield server
  ensure
    server&.stop
  end

  def initialize(app)
    @puma = Puma::Server.new(app, nil, min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null)
    @puma.add_tcp_listener("127.0.0.1", 0)
    @port = @puma.connected_ports.first
    @puma.run
  end

  def url
    "http://127.0.0.1:#{port}"
  end

  def stop
    @puma.stop(true)
  end
end
