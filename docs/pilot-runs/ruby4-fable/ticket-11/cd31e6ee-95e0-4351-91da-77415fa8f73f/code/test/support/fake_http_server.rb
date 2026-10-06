# frozen_string_literal: true

require "digest"
require "json"
require "socket"
require "time"
require "uri"

# A minimal in-memory implementation of the Syncbox HTTP API (GET /blobs,
# PUT/GET/DELETE /blobs/{key}, GET /healthz) on a raw TCP socket, for driving
# the real client — in-process or as a child process — through failures the
# real server would not produce on purpose:
#
#   fail:        key => status; PUT and GET of that key answer the status
#                (with a JSON error body) instead of storing/serving it
#   hang:        :all, or an Array of "METHOD /path" strings — the server
#                reads such a request and never answers it (until closed)
#   stop_after:  after this many requests the listening socket is closed and
#                every connection dropped, as if the server had crashed
#
# Speaks HTTP/1.1 with keep-alive, one thread per connection. Every request
# is logged as [method, path].
class FakeHttpServer
  attr_reader :port, :blobs

  def self.open(**options)
    server = new(**options)
    yield server
  ensure
    server&.close
  end

  def initialize(blobs: {}, fail: {}, hang: [], stop_after: nil)
    @blobs = blobs.dup # key => content
    @fail = fail
    @hang = hang
    @stop_after = stop_after
    @socket = TCPServer.new("127.0.0.1", 0)
    @port = @socket.addr[1]
    @requests = []
    @connections = []
    @mutex = Mutex.new
    @closed = false
    @acceptor = Thread.new { accept_loop }
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  def close
    sockets = @mutex.synchronize do
      @closed = true
      @connections.dup << @socket
    end
    sockets.each { |s| s.close rescue nil } # rubocop:disable Style/RescueModifier
    @acceptor.join(5)
  end

  private

  def accept_loop
    loop do
      conn = @socket.accept
      @mutex.synchronize { @connections << conn }
      Thread.new { serve(conn) }
    end
  rescue IOError, SystemCallError
    nil # listening socket closed
  end

  def serve(conn)
    while (request_line = conn.gets)
      method, raw_path, = request_line.split(" ")
      headers = {}
      while (line = conn.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      body = headers["content-length"] ? conn.read(headers["content-length"].to_i) : ""
      count = @mutex.synchronize { @requests << [method, raw_path]; @requests.size }

      return hang(conn) if @hang == :all || Array(@hang).include?("#{method} #{raw_path}")

      status, type, payload = handle(method, raw_path, body)
      conn.write "HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}"
      conn.flush
      crash if @stop_after && count >= @stop_after
    end
  rescue IOError, SystemCallError
    nil
  ensure
    conn.close rescue nil # rubocop:disable Style/RescueModifier
  end

  # Never answers; returns when the server is closed.
  def hang(conn)
    sleep 0.05 until @mutex.synchronize { @closed }
    conn.close rescue nil # rubocop:disable Style/RescueModifier
  end

  def crash
    close_all = @mutex.synchronize do
      @closed = true
      @connections.dup << @socket
    end
    close_all.each { |s| s.close rescue nil } # rubocop:disable Style/RescueModifier
  end

  def handle(method, raw_path, body)
    path = raw_path.split("?", 2).first
    return ["200 OK", "text/plain", "ok"] if method == "GET" && path == "/healthz"
    return ["200 OK", "application/json", JSON.generate(listing)] if method == "GET" && path == "/blobs"

    return ["404 Not Found", "application/json", JSON.generate("error" => "no route")] unless path.start_with?("/blobs/")

    key = URI.decode_uri_component(path.delete_prefix("/blobs/")).force_encoding(Encoding::UTF_8)
    if (status = @fail[key]) && %w[PUT GET].include?(method)
      return ["#{status} #{ClientFailureHelpers::REASONS.fetch(status)}", "application/json",
              JSON.generate("error" => "injected failure", "detail" => "#{method} #{key} is configured to fail")]
    end

    case method
    when "PUT"
      @mutex.synchronize { @blobs[key] = body.b }
      ["201 Created", "application/json", JSON.generate("key" => key, "sha256" => Digest::SHA256.hexdigest(body), "size" => body.bytesize)]
    when "GET"
      content = @mutex.synchronize { @blobs[key] }
      return ["404 Not Found", "application/json", JSON.generate("error" => "not found")] unless content

      ["200 OK", "application/octet-stream", content]
    when "DELETE"
      removed = @mutex.synchronize { @blobs.delete(key) }
      removed ? ["204 No Content", "text/plain", ""] : ["404 Not Found", "application/json", JSON.generate("error" => "not found")]
    else
      ["405 Method Not Allowed", "text/plain", ""]
    end
  end

  def listing
    @mutex.synchronize do
      @blobs.sort.map do |key, content|
        { "key" => key, "size" => content.bytesize, "sha256" => Digest::SHA256.hexdigest(content),
          "modified_at" => "2026-01-01T00:00:00.000Z" }
      end
    end
  end
end
