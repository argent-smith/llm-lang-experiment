# frozen_string_literal: true

require "test_helper"

# HTTP-клиент: кодирование key в URL и обращения к настоящему серверу.
class ClientApiTest < Minitest::Test
  include Syncbox::TestSupport

  Api = Syncbox::Client::Api

  def setup
    @tmp = Dir.mktmpdir("syncbox-api")
    @server = nil
  end

  def teardown
    @server&.stop
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def start_server
    @server = Syncbox::TestSupport::ServerProcess.new(File.join(@tmp, "data"))
  end

  def test_escape_key_keeps_slashes_and_unreserved_characters_only
    assert_equal "docs/readme.txt", Api.escape_key("docs/readme.txt")
    assert_equal "a%20b/c~d-e_f.g", Api.escape_key("a b/c~d-e_f.g")
    assert_equal "%25/%3F/%23/%2B/%26/%3D/%3A/%40", Api.escape_key("%/?/#/+/&/=/:/@")
    assert_equal "%C3%BC/%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82.txt", Api.escape_key("ü/привет.txt")
    assert_equal "%5C/%27%22%60", Api.escape_key("\\/'\"`")
  end

  def test_list_and_put_against_a_real_server
    start_server
    Api.open(URI(@server.url)) do |api|
      assert_equal [], api.list_blobs

      File.binwrite(File.join(@tmp, "payload"), "hello")
      meta = File.open(File.join(@tmp, "payload"), "rb") { |f| api.put_blob("docs/hi там.txt", f, 5) }
      assert_equal({ "key" => "docs/hi там.txt", "sha256" => Digest::SHA256.hexdigest("hello"), "size" => 5 }, meta)

      list = api.list_blobs
      assert_equal ["docs/hi там.txt"], list.map { |m| m["key"] }
      assert_equal 5, list.first["size"]
    end
    assert_equal "hello", @server.blob("docs/hi там.txt")
  end

  def test_put_streams_exactly_size_bytes_from_the_current_position
    start_server
    path = File.join(@tmp, "payload")
    File.binwrite(path, "skip-me" + ("\x00\xff".b * 100_000))
    expected = ("\x00\xff".b * 100_000)
    Api.open(URI(@server.url)) do |api|
      File.open(path, "rb") do |f|
        f.read(7)
        meta = api.put_blob("big.bin", f, expected.bytesize)
        assert_equal Digest::SHA256.hexdigest(expected), meta["sha256"]
        assert_equal expected.bytesize, meta["size"]
      end
    end
    assert_equal expected, @server.blob("big.bin")
  end

  def test_server_path_prefix_is_honoured
    start_server
    Api.open(URI("#{@server.url}/nope")) do |api|
      error = assert_raises(Syncbox::Client::Error) { api.list_blobs }
      assert_match(%r{GET /blobs: server responded 404}, error.message)
    end
  end

  def test_unexpected_status_becomes_an_error_with_the_server_message
    start_server
    Api.open(URI(@server.url)) do |api|
      error = assert_raises(Syncbox::Client::Error) { api.put_blob("../escape", StringIO.new("x"), 1) }
      assert_match(%r{PUT /blobs/\.\./escape: server responded 400: key must not contain '\.' or '\.\.' segments}, error.message)
      error = assert_raises(Syncbox::Client::Error) { api.put_blob(".syncbox-tmp/x", StringIO.new("x"), 1) }
      assert_match(/server responded 400: key uses reserved name/, error.message)
    end
  end

  def test_unreachable_server_is_an_error_not_a_hang
    port = free_port
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Syncbox::Client::Error) { Api.open(URI("http://127.0.0.1:#{port}")) { |api| api.list_blobs } }
    assert_match(%r{cannot connect to server http://127\.0\.0\.1:#{port}: .*}, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, Api::OPEN_TIMEOUT
  end

  def test_connection_lost_mid_session_is_an_error
    start_server
    Api.open(URI(@server.url)) do |api|
      assert_equal [], api.list_blobs
      @server.stop
      error = assert_raises(Syncbox::Client::Error) { api.list_blobs }
      assert_match(%r{GET /blobs: request to http://127\.0\.0\.1:\d+ failed}, error.message)
    end
  end

  def test_non_json_body_is_an_error
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n")
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5\r\nConnection: close\r\n\r\n<html")
      client.close
    end
    error = assert_raises(Syncbox::Client::Error) { Api.open(URI("http://127.0.0.1:#{port}")) { |api| api.list_blobs } }
    assert_match(%r{GET /blobs: server returned invalid JSON}, error.message)
  ensure
    thread&.join(5)
    server&.close
  end
end
