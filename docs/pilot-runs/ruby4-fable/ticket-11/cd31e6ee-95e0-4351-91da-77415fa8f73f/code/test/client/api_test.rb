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

  def test_connection_refused_is_unreachable_and_names_the_cause
    port = free_port
    api = api_for(port)
    error = assert_raises(Api::Unreachable) { api.list }
    assert_equal "cannot reach server at http://127.0.0.1:#{port}: connection refused by 127.0.0.1:#{port} " \
                 "(is the server running there?) (GET /blobs)", error.message
    refute error.timeout?
  end

  def test_unresolvable_host_is_unreachable_and_names_the_cause
    api = Api.new(URI.parse("http://no-such-host.invalid:1"), open_timeout: 5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Api::Unreachable) { api.list }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15, "name resolution must be bounded"
    assert_match(/\Acannot reach server at http:\/\/no-such-host\.invalid:1: /, error.message)
    # Resolution normally fails outright; a resolver that does not answer at
    # all is cut off by the open timeout instead.
    assert_match(/cannot resolve host name "no-such-host\.invalid" \(.+\)|connection to no-such-host\.invalid:1 timed out after 5s/, error.message)
    assert_match(/\(GET \/blobs\)\z/, error.message)
  end

  # The spec's "server unavailable (timeout)" case: the server accepts the
  # connection, reads the request and never answers. The read timeout ends
  # the wait, the error says so in seconds, and nothing hangs.
  def test_a_server_that_never_answers_is_unreachable_after_the_read_timeout
    FakeHttpServer.open(hang: :all) do |server|
      api = Api.new(URI.parse(server.url), read_timeout: 1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Api::Unreachable) { api.list }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :>=, 0.9
      assert_operator elapsed, :<, 5, "the read timeout must end the wait"
      assert_equal "cannot reach server at #{server.url}: no response from 127.0.0.1:#{server.port} within 1s " \
                   "(read timeout) (GET /blobs)", error.message
      assert error.timeout?
      assert_equal [["GET", "/blobs"]], server.requests
    end
  end

  # A stale keep-alive connection is retried once (see below), a timeout is
  # not: the server was reached and did not answer, and asking again would
  # only double the wait — and resend a PUT the server may be processing.
  def test_a_timeout_on_a_reused_connection_is_not_retried
    with_tmpdir do |dir|
      File.write(File.join(dir, "payload"), "x")
      FakeHttpServer.open(hang: ["PUT /blobs/slow"]) do |server|
        api = Api.new(URI.parse(server.url), read_timeout: 1)
        begin
          assert_equal [], api.list, "the first request succeeds and leaves a keep-alive connection"
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          error = assert_raises(Api::Unreachable) { api.put("slow", File.join(dir, "payload")) }
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          assert_operator elapsed, :<, 1.9, "a retry would have waited for a second timeout"
          assert_match(/no response from .* within 1s \(read timeout\) \(PUT \/blobs\/slow\)/, error.message)
          assert_equal [["GET", "/blobs"], ["PUT", "/blobs/slow"]], server.requests, "the PUT is sent exactly once"
        ensure
          api.close
        end
      end
    end
  end

  def test_the_default_timeouts_are_explicit_and_finite
    api = api_for(1)
    assert_equal [10, 60, 60], [api.open_timeout, api.read_timeout, api.write_timeout]
    assert_equal [Api::OPEN_TIMEOUT, Api::READ_TIMEOUT, Api::WRITE_TIMEOUT], [api.open_timeout, api.read_timeout, api.write_timeout]
  end

  def test_a_5xx_answer_is_an_http_error_not_an_unreachable_server
    with_tmpdir do |dir|
      File.write(File.join(dir, "payload"), "x")
      FakeHttpServer.open(fail: { "broken" => 500 }) do |server|
        api = Api.new(URI.parse(server.url))
        begin
          error = assert_raises(Api::HttpError) { api.put("broken", File.join(dir, "payload")) }
          assert_equal 500, error.status
          assert_equal "server answered 500 Internal Server Error to PUT /blobs/broken: PUT broken is configured to fail", error.message
          error = assert_raises(Api::HttpError) { api.get("broken", File.join(dir, "out")) }
          assert_equal 500, error.status
          assert_equal [], api.list, "the connection is still usable afterwards"
        ensure
          api.close
        end
      end
    end
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

  def test_get_streams_a_blob_into_a_file_and_reports_its_hash
    with_tmpdir do |dir|
      data = Random.new(43).bytes(2 * 1024 * 1024 + 17)
      File.binwrite(File.join(dir, "big"), data)
      with_running_server(File.join(dir, "store")) do |port|
        api = api_for(port)
        begin
          api.put("sp ace/ü.bin", File.join(dir, "big"))
          api.put("empty", File.join(dir, "big")) # replaced below
          File.binwrite(File.join(dir, "zero"), "")
          api.put("empty", File.join(dir, "zero"))

          target = File.join(dir, "downloaded")
          result = api.get("sp ace/ü.bin", target)
          assert_equal "sp ace/ü.bin", result.key
          assert_equal data.bytesize, result.size
          assert_equal Digest::SHA256.hexdigest(data), result.sha256
          assert_equal data, File.binread(target)

          File.binwrite(target, "stale")
          result = api.get("empty", target)
          assert_equal [0, Digest::SHA256.hexdigest("")], [result.size, result.sha256]
          assert_equal "", File.binread(target), "the target is truncated, not appended to"
        ensure
          api.close
        end
      end
    end
  end

  def test_get_of_a_missing_key_is_a_404_http_error_and_the_connection_stays_usable
    with_tmpdir do |dir|
      with_running_server(File.join(dir, "store")) do |port|
        api = api_for(port)
        begin
          target = File.join(dir, "out")
          error = assert_raises(Api::HttpError) { api.get("nope.txt", target) }
          assert_equal 404, error.status
          assert_match(%r{server answered 404 Not Found to GET /blobs/nope\.txt: not found}, error.message)
          assert_equal "", File.binread(target), "the error body is not written to the file"
          assert_equal [], api.list, "the 404 body was drained; the keep-alive connection still works"
        ensure
          api.close
        end
      end
    end
  end

  def test_get_with_a_truncated_body_is_unreachable_not_a_short_file
    with_fake_server("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc") do |port|
      with_tmpdir do |dir|
        target = File.join(dir, "out")
        error = assert_raises(Api::Unreachable) { Api.new(URI.parse("http://127.0.0.1:#{port}"), read_timeout: 3).get("k", target) }
        assert_match(%r{cannot reach server .*\(GET /blobs/k\)}, error.message)
      end
    end
  end

  def test_get_that_cannot_write_the_file_is_a_write_error_not_a_network_error
    skip "/dev/full is not available" unless File.exist?("/dev/full") && File.writable?("/dev/full")

    with_tmpdir do |dir|
      File.write(File.join(dir, "payload"), "hello")
      with_running_server(File.join(dir, "store")) do |port|
        api = api_for(port)
        begin
          api.put("k", File.join(dir, "payload"))
          error = assert_raises(Api::WriteError) { api.get("k", "/dev/full") }
          assert_match(%r{\Acannot write /dev/full: No space left on device}, error.message)
          assert_equal ["k"], api.list.map(&:key), "a fresh connection is opened after the failed download"
        ensure
          api.close
        end
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
