# frozen_string_literal: true

require "puma"
require "puma/server"
require "rack"

# The real server application (Syncbox::Server::App over a Storage in +data+)
# run in-process by Puma, with faults injected for chosen blob keys:
#
#   server.fail("PUT", "b")          # answers 500 to PUT /blobs/b
#   server.fail("GET", "b", :drop)   # closes the connection instead of answering
#   server.fail("GET", "b", :hang)   # never answers (until #stop)
#
# Every other request is served as usual.
class FaultyServer
  def initialize(data)
    # The port is not used: Puma listens on one of its own.
    config = Syncbox::Server::Config.new(data_dir: data, port: "8080")
    config.prepare_data_dir!
    storage = Syncbox::Server::Storage.new(data)
    storage.prepare!
    @app = Syncbox::Server::App.new(config, storage: storage)
    @faults = {}
    @release = Queue.new
    @puma = Puma::Server.new(method(:call), nil, min_threads: 0, max_threads: 8, log_writer: Puma::LogWriter.null)
    @port = @puma.add_tcp_listener("127.0.0.1", 0).addr[1]
    @puma.run
  end

  attr_reader :port

  def url
    "http://127.0.0.1:#{@port}"
  end

  def fail(method, key, fault = :error)
    @faults[[method, key]] = fault
  end

  def stop
    @release.close
    @puma.stop(true)
  end

  def call(env)
    key = Rack::Utils.unescape_path(env["PATH_INFO"].delete_prefix("/blobs/")) if env["PATH_INFO"].start_with?("/blobs/")
    case @faults[[env["REQUEST_METHOD"], key]]
    when :error
      [500, { "content-type" => "text/plain" }, ["injected failure\n"]]
    when :drop
      env["rack.hijack"].call.close
      [200, {}, []]
    when :hang
      @release.pop(timeout: 60)
      [500, {}, []]
    else
      @app.call(env)
    end
  end
end
