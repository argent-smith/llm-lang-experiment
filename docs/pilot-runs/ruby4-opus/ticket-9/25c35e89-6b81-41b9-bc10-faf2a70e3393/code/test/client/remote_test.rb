# frozen_string_literal: true

require "test_helper"
require "socket"

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

    error = assert_raises(Syncbox::Client::Error) do
      Syncbox::Client::Remote.open(URI("http://127.0.0.1:#{port}")) { |remote| remote.list }
    end
    assert_match(%r{cannot list blobs: server http://127\.0\.0\.1:#{port} is unreachable: .*refused}, error.message)
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

  def test_server_closing_the_connection_is_an_error
    error = assert_raises(Syncbox::Client::Error) do
      stub_server("") { |url| Syncbox::Client::Remote.open(URI(url), &:list) }
    end
    assert_match(/cannot list blobs: server .* is unreachable/, error.message)
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
      "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort" => /\Acannot download k: server .* is unreachable/,
      "" => /\Acannot download k: server .* is unreachable/ }.each do |response, message|
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

  def remote(url)
    Syncbox::Client::Remote.new(URI(url))
  end
end
