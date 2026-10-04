# frozen_string_literal: true

require "test_helper"
require "socket"
require "stringio"

class RemoteTest < Minitest::Test
  def test_blob_path_keeps_slashes_and_percent_encodes_the_rest
    remote = remote("http://h:8080")

    assert_equal "/blobs/docs/readme.txt", remote.blob_path("docs/readme.txt")
    assert_equal "/blobs/a%20b/100%25/q%3Fx/%23f/%E2%9C%93/a%5Cb/~-_.",
                 remote.blob_path("a b/100%/q?x/#f/✓/a\\b/~-_.")
    assert_equal "/blobs/%252E%252E%252Fx", remote.blob_path("%2E%2E%2Fx") # a literal name, not ../x
  end

  def test_blob_path_under_a_base_path
    assert_equal "/blobs/k", remote("http://h/").blob_path("k")
    assert_equal "/syncbox/blobs/k", remote("http://h/syncbox//").blob_path("k")
  end

  def test_unreachable_server_is_an_error
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }

    error = assert_raises(Syncbox::Client::Remote::Unreachable) do
      Syncbox::Client::Remote.open(URI("http://127.0.0.1:#{port}")) { |remote| remote.list }
    end
    assert_equal "cannot list blobs: server http://127.0.0.1:#{port} is unreachable: connection refused", error.message
  end

  def test_unresolvable_host_name_is_unreachable
    error = assert_raises(Syncbox::Client::Remote::Unreachable) do
      Syncbox::Client::Remote.open(URI("http://no-such-host.invalid:8080"), &:list)
    end
    assert_match(%r{\Acannot list blobs: server http://no-such-host\.invalid:8080 is unreachable: cannot resolve host name no-such-host\.invalid \(.+\)\z}, error.message)
  end

  def test_every_network_operation_has_a_timeout
    http = remote("http://h:8080").instance_variable_get(:@http)

    assert_equal [10, 60, 60], [http.open_timeout, http.read_timeout, http.write_timeout]
  end

  def test_server_that_does_not_answer_times_out
    silent_server do |url|
      started = Time.now
      error = assert_raises(Syncbox::Client::Remote::Unreachable) do
        Syncbox::Client::Remote.open(URI(url), read_timeout: 1, &:list)
      end

      assert_equal "cannot list blobs: server #{url} is unreachable: no response within 1s", error.message
      assert_operator Time.now - started, :<, 5
    end
  end

  def test_upload_waits_longer_for_the_answer_the_larger_the_blob
    silent_server do |url|
      started = Time.now
      error = assert_raises(Syncbox::Client::Remote::Unreachable) do
        Syncbox::Client::Remote.open(URI(url), read_timeout: 1) do |remote|
          remote.put("k", StringIO.new("x" * (2 * Syncbox::Client::Remote::PUT_BYTES_PER_SECOND)))
        end
      end

      assert_equal "cannot upload k: server #{url} is unreachable: no response within 3s", error.message
      assert_operator Time.now - started, :>=, 2.5
    end
  end

  def test_unexpected_list_responses_are_errors
    ["HTTP/1.1 500 Internal Server Error\r\nContent-Length: 4\r\n\r\nboom",
     "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nnot json",
     "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n[{\"key\":\"a\"}]",
     "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"].each do |response|
      error = assert_raises(Syncbox::Client::Error, response) do
        stub_server(response) { |url| Syncbox::Client::Remote.open(URI(url), &:list) }
      end
      assert_match(/\Acannot list blobs: (server answered 500 boom|unexpected response from server)/, error.message)
    end
  end

  def test_server_closing_the_connection_is_an_error_of_that_request_only
    error = assert_raises(Syncbox::Client::Error) do
      stub_server("") { |url| Syncbox::Client::Remote.open(URI(url), &:list) }
    end
    refute_kind_of Syncbox::Client::Remote::Unreachable, error
    assert_match(%r{\Acannot list blobs: connection to server http://\S+ failed: the server closed the connection\z},
                 error.message)
  end

  def test_next_request_after_a_broken_one_connects_anew
    body = "[]"
    responses = ["", "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"]
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      responses.each do |response|
        client = server.accept
        nil until client.gets.to_s.strip.empty?
        client.write(response)
        client.close
      end
    end

    Syncbox::Client::Remote.open(URI("http://127.0.0.1:#{server.addr[1]}")) do |remote|
      assert_raises(Syncbox::Client::Error) { remote.list }
      assert_equal({}, remote.list)
    end
  ensure
    thread&.join(5)
    server&.close
  end

  def test_list_keeps_modified_at
    body = '[{"key":"a","size":1,"sha256":"' + ("0" * 64) + '","modified_at":"2026-01-02T03:04:05.678901Z"}]'

    blobs = stub_server("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}") do |url|
      Syncbox::Client::Remote.open(URI(url), &:list)
    end

    assert_equal "2026-01-02T03:04:05.678901Z", blobs.fetch("a").modified_at
  end

  def test_put_returns_the_stored_sha256
    sha256 = "a" * 64
    { %({"key":"k","sha256":"#{sha256}","size":3}) => sha256, "not json" => nil, "[]" => nil }.each do |body, expected|
      stored = stub_server("HTTP/1.1 201 Created\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}") do |url|
        Syncbox::Client::Remote.open(URI(url)) { |remote| remote.put("k", StringIO.new("abc")) }
      end

      expected ? assert_equal(expected, stored, body) : assert_nil(stored, body)
    end
  end

  def test_get_yields_the_blob_in_chunks
    body = Random.new(4).bytes(300_000)
    chunks = []

    stub_server("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}") do |url|
      Syncbox::Client::Remote.open(URI(url)) { |remote| remote.get("docs/a b") { |chunk| chunks << chunk } }
    end

    assert_operator chunks.size, :>, 1
    assert_equal body, chunks.join.b
    assert_equal "GET /blobs/docs/a%20b HTTP/1.1", @request_line
  end

  def test_get_of_a_missing_blob_is_not_found
    error = assert_raises(Syncbox::Client::Remote::NotFound) do
      stub_server("HTTP/1.1 404 Not Found\r\nContent-Length: 10\r\n\r\nnot found\n") do |url|
        Syncbox::Client::Remote.open(URI(url)) { |remote| remote.get("k") { flunk } }
      end
    end
    assert_equal "cannot download k: not found on the server", error.message
  end

  def test_get_failures_are_errors
    { "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\n\r\ninvalid key\n" => /\Acannot download k: server answered 400 invalid key\z/,
      "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n" => /\Acannot download k: server answered 503 Service Unavailable\z/,
      "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort" => /\Acannot download k: connection to server .* failed: the server closed the connection\z/,
      "" => /\Acannot download k: connection to server .* failed: the server closed the connection\z/ }.each do |response, message|
      error = assert_raises(Syncbox::Client::Error, response) do
        stub_server(response) { |url| Syncbox::Client::Remote.open(URI(url)) { |remote| remote.get("k") { nil } } }
      end
      assert_match message, error.message
    end
  end

  def test_get_passes_errors_of_the_block_through
    error = assert_raises(Syncbox::Client::Error) do
      stub_server("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc") do |url|
        Syncbox::Client::Remote.open(URI(url)) { |remote| remote.get("k") { raise Syncbox::Client::Error, "disk full" } }
      end
    end
    assert_equal "disk full", error.message
  end

  private

  # Answers one request with the raw +response+, then closes the connection.
  # The request line received is left in @request_line.
  def stub_server(response)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      @request_line = client.gets.to_s.strip
      nil until client.gets.to_s.strip.empty?
      client.write(response)
      client.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    thread&.join(5)
    server&.close
  end

  # Accepts connections and reads requests, but never answers.
  def silent_server
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      client.read
    rescue IOError, SystemCallError
      nil
    ensure
      client&.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill&.join(5)
  end

  def remote(url)
    Syncbox::Client::Remote.new(URI(url))
  end
end
