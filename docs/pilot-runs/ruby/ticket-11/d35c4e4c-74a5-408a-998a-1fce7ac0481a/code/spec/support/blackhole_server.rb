require "socket"

# A TCP listener that accepts connections but never writes a response --
# simulates a server that's up (TCP connect succeeds) yet hangs forever, so
# specs can exercise Client's read_timeout without needing a real server
# that's merely slow.
class BlackholeServer
  def self.start
    new.tap(&:start)
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new do
      loop { @server.accept }
    rescue IOError, Errno::EBADF
      # #stop closed the listener out from under #accept; just exit.
    end
  end

  def port
    @server.addr[1]
  end

  def url
    "http://127.0.0.1:#{port}"
  end

  def stop
    @server.close
    @thread.join
  end
end
