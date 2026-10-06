# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"

class ClientApiTest < Minitest::Test
  include TestHelpers
  include ServerProcessHelpers

  Api = Syncbox::Client::Api

  def api_for(port, path: "")
    Api.new(URI.parse("http://127.0.0.1:#{port}#{path}"))
  end

  def test_encode_key_escapes_everything_but_unreserved_characters_and_slashes
    assert_equal "docs/readme.txt", Api.encode_key("docs/readme.txt")
    assert_equal "sp%20ace/%C3%BC.txt", Api.encode_key("sp ace/ü.txt")
    assert_equal "a%2Bb%25c%3Fd%23e%26f%3Dg", Api.encode_key("a+b%c?d#e&f=g")
    assert_equal "~-_.", Api.encode_key("~-_.")
    assert_equal "%E2%9C%93", Api.encode_key("✓")
  end

  def test_blob_path_includes_the_server_prefix
    assert_equal "/blobs/a%20b", api_for(1).blob_path("a b")
    assert_equal "/prefix/blobs/a", api_for(1, path: "/prefix").blob_path("a")
  end

  def test_list_and_put_against_the_real_server
    with_tmpdir do |dir|
      File.write(File.join(dir, "payload"), "hello")
      with_running_server(File.join(dir, "store")) do |port|
        api = api_for(port)
        begin
          assert_equal [], api.list

          result = api.put("sp ace/ü.txt", File.join(dir, "payload"))
          assert_equal "sp ace/ü.txt", result.key
          assert_equal Digest::SHA256.hexdigest("hello"), result.sha256
          assert_equal 5, result.size

          list = api.list
          assert_equal ["sp ace/ü.txt"], list.map(&:key)
          assert_equal Digest::SHA256.hexdigest("hello"), list.first.sha256
          assert_equal 5, list.first.size
          assert_match(/\A\d{4}-\d\d-\d\dT/, list.first.modified_at)

          response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/blobs/sp%20ace/%C3%BC.txt"))
          assert_equal "hello", response.body
        ensure
          api.close
        end
      end
    end
  end

  def test_put_streams_large_files
    with_tmpdir do |dir|
      data = Random.new(42).bytes(3 * 1024 * 1024)
      File.binwrite(File.join(dir, "big"), data)
      with_running_server(File.join(dir, "store")) do |port|
        api = api_for(port)
        begin
          result = api.put("big.bin", File.join(dir, "big"))
          assert_equal Digest::SHA256.hexdigest(data), result.sha256
          assert_equal data.bytesize, result.size
        ensure
          api.close
        end
      end
    end
  end

  def test_unexpected_status_is_an_http_error_with_the_server_detail
    with_tmpdir do |dir|
      File.write(File.join(dir, "payload"), "x")
      with_running_server(File.join(dir, "store")) do |port|
        api = api_for(port)
        begin
          error = assert_raises(Api::HttpError) { api.put("../escape", File.join(dir, "payload")) }
          assert_equal 400, error.status
          assert_match(/server answered 400 Bad Request to PUT \/blobs\/\.\.\/escape: key must not contain/, error.message)

          error = assert_raises(Api::HttpError) { api_for(port, path: "/healthz").list }
          assert_equal 404, error.status
        ensure
          api.close
        end
      end
    end
  end

  def test_connection_refused_is_unreachable
    port = free_port
    api = api_for(port)
    error = assert_raises(Api::Unreachable) { api.list }
    assert_match(/cannot reach server at http:\/\/127\.0\.0\.1:#{port}: .*refused/i, error.message)
    assert_match(/GET \/blobs/, error.message)
  end

  def test_unresolvable_host_is_unreachable
    api = Api.new(URI.parse("http://no-such-host.invalid:1"), open_timeout: 5)
    error = assert_raises(Api::Unreachable) { api.list }
    assert_match(/cannot reach server at http:\/\/no-such-host\.invalid:1/, error.message)
  end

  def test_non_json_or_malformed_bodies_are_protocol_errors
    with_fake_server("HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot json!") do |port|
      error = assert_raises(Api::ProtocolError) { api_for(port).list }
      assert_match(/not valid JSON/, error.message)
    end
    with_fake_server("HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n[{\"key\": 42}]") do |port|
      error = assert_raises(Api::ProtocolError) { api_for(port).list }
      assert_match(/malformed list entry/, error.message)
    end
    with_fake_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}") do |port|
      error = assert_raises(Api::ProtocolError) { api_for(port).list }
      assert_match(/expected a JSON array/, error.message)
    end
  end

  def test_server_closing_the_connection_mid_response_is_unreachable
    with_fake_server("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n[") do |port|
      error = assert_raises(Api::Unreachable) { Api.new(URI.parse("http://127.0.0.1:#{port}"), read_timeout: 3).list }
      assert_match(/cannot reach server/, error.message)
    end
  end

  # A request on a keep-alive connection that the server has since closed is
  # retried once on a fresh connection, so the caller never sees the stale
  # connection. The fake server answers one request per connection.
  def test_stale_keep_alive_connection_is_retried_once
    body = "[]"
    response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
    with_fake_server(response, connections: 2, close_after_response: true) do |port|
      api = api_for(port)
      begin
        assert_equal [], api.list
        assert_equal [], api.list, "second request must succeed on a new connection"
      ensure
        api.close
      end
    end
  end

  private

  # Minimal TCP server that reads one request's headers and answers with the
  # given raw bytes. Serves +connections+ connections, then stops.
  def with_fake_server(raw_response, connections: 1, close_after_response: true)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      connections.times do
        sock = server.accept
        begin
          Timeout.timeout(5) { loop { break if sock.gets.to_s.strip.empty? } }
          sock.write(raw_response)
          sock.flush
          sleep 0.05 unless close_after_response
        ensure
          sock.close
        end
      end
    rescue IOError, SystemCallError
      nil
    end
    yield port
  ensure
    server&.close
    thread&.join(5)
  end
end
