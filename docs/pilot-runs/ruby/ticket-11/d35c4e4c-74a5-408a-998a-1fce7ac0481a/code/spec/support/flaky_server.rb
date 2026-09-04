require "puma"
require "syncbox/server"

# Wraps a real Syncbox::Server on an ephemeral loopback port, but forces a
# 500 response for exactly one request (method + path) instead of routing
# it to the real app. Lets specs simulate "the server returns 5xx for one
# specific key" -- a partial failure mid-push/pull/sync -- without needing
# the server itself to misbehave.
class FlakyServer
  attr_reader :port

  # fail_on: [http_method, path], e.g. ["PUT", "/blobs/bad.txt"].
  def self.start(data_dir, fail_on:)
    new(data_dir, fail_on: fail_on).tap(&:start)
  end

  def initialize(data_dir, fail_on:)
    @data_dir = data_dir
    @fail_on = fail_on
  end

  def start
    Syncbox::Server.set(:data_dir, @data_dir)
    fail_on = @fail_on

    rack_app = lambda do |env|
      if [env["REQUEST_METHOD"], env["PATH_INFO"]] == fail_on
        [500, { "Content-Type" => "text/plain" }, ["injected failure"]]
      else
        Syncbox::Server.call(env)
      end
    end

    @puma = Puma::Server.new(rack_app)
    listener = @puma.add_tcp_listener("127.0.0.1", 0)
    @port = listener.addr[1]
    @thread = @puma.run
  end

  def url
    "http://127.0.0.1:#{port}"
  end

  def stop
    @puma.stop(true)
    @thread.join
  end
end
