require "puma"
require "syncbox/server"

# Boots a real Syncbox::Server instance on an ephemeral loopback port, so
# client-side specs exercise Syncbox::Client/Push/CLI over actual HTTP
# instead of mocking the transport.
class TestServer
  attr_reader :port

  def self.start(data_dir)
    new(data_dir).tap(&:start)
  end

  def initialize(data_dir)
    @data_dir = data_dir
  end

  def start
    Syncbox::Server.set(:data_dir, @data_dir)
    @puma = Puma::Server.new(Syncbox::Server)
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
