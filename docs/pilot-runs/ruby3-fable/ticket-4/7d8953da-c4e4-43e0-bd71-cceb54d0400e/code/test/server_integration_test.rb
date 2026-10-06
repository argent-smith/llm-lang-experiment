# frozen_string_literal: true

require "test_helper"
require "net/http"
require "open3"

# Интеграционные тесты: запускают настоящий bin/syncbox-server как отдельный
# процесс, ходят в него по HTTP и проверяют корректное завершение по SIGTERM.
class ServerIntegrationTest < Minitest::Test
  include Syncbox::TestSupport

  def setup
    @tmp = Dir.mktmpdir("syncbox-test")
    @pid = nil
  end

  def teardown
    if @pid && Process.waitpid(@pid, Process::WNOHANG).nil?
      Process.kill("KILL", @pid)
      Process.wait(@pid)
    end
  rescue Errno::ECHILD, Errno::ESRCH
    # процесс уже завершился и был забран самим тестом
  ensure
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def spawn_server(*args, env: {})
    log = File.join(@tmp, "server.log")
    base_env = { "SYNCBOX_DATA_DIR" => nil, "SYNCBOX_PORT" => nil }
    @pid = Process.spawn(base_env.merge(env), SERVER_BIN, *args, out: log, err: log)
    @log = log
    @pid
  end

  def test_healthz_over_http_with_flags
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)

    response = wait_for_healthz(port, pid: @pid)
    assert_equal "200", response.code
    assert_equal({ "status" => "ok" }, JSON.parse(response.body))
    assert File.directory?(data_dir), "server should create its data dir"

    Process.kill("TERM", @pid)
    _, status = Process.wait2(@pid)
    assert status.success?, "server should exit cleanly on SIGTERM, got #{status.inspect}\n#{File.read(@log)}"
  end

  def test_configuration_via_environment_variables
    port = free_port
    data_dir = File.join(@tmp, "env-data")
    spawn_server(env: { "SYNCBOX_DATA_DIR" => data_dir, "SYNCBOX_PORT" => port.to_s })

    response = wait_for_healthz(port, pid: @pid)
    assert_equal "200", response.code
    assert File.directory?(data_dir)
  end

  def test_blob_endpoints_over_http
    port = free_port
    spawn_server("--data-dir", File.join(@tmp, "data"), "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)

    # Ровно как в отчёте проверки: PUT без тела с octet-stream и GET списка.
    response = http.request(Net::HTTP::Put.new("/blobs/0", "content-type" => "application/octet-stream"))
    assert_equal "201", response.code, response.body
    assert_equal({ "key" => "0", "sha256" => Digest::SHA256.hexdigest(""), "size" => 0 }, JSON.parse(response.body))

    response = http.get("/blobs")
    assert_equal "200", response.code
    assert_equal ["0"], JSON.parse(response.body).map { |m| m["key"] }

    payload = (0..255).map(&:chr).join.b * 1000
    request = Net::HTTP::Put.new("/blobs/dir/data.bin", "content-type" => "application/octet-stream")
    request.body = payload
    response = http.request(request)
    assert_equal "201", response.code
    assert_equal Digest::SHA256.hexdigest(payload), JSON.parse(response.body)["sha256"]

    response = http.get("/blobs/dir/data.bin")
    assert_equal "200", response.code
    assert_equal payload, response.body.b

    assert_equal "400", http.request(Net::HTTP::Put.new("/blobs/../escape")).code
    assert_equal "400", http.request(Net::HTTP::Put.new("/blobs/%ed%a0%80")).code
    assert_equal "404", http.get("/blobs/nope").code

    assert_equal "204", http.delete("/blobs/dir/data.bin").code
    assert_equal "404", http.delete("/blobs/dir/data.bin").code
  end

  def test_list_blobs_over_http
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)

    response = http.get("/blobs")
    assert_equal "200", response.code
    assert_match %r{\Aapplication/json}, response["content-type"]
    assert_equal [], JSON.parse(response.body)

    { "docs/readme.txt" => "hello", "a.bin" => "\x00\xff".b, "x/y/z" => "" }.each do |key, body|
      request = Net::HTTP::Put.new("/blobs/#{key}", "content-type" => "application/octet-stream")
      request.body = body
      assert_equal "201", http.request(request).code
    end
    FileUtils.mkdir_p(File.join(data_dir, "ext"))
    File.binwrite(File.join(data_dir, "ext", "on-disk"), "disk")

    response = http.get("/blobs")
    assert_equal "200", response.code
    list = JSON.parse(response.body)
    assert_equal ["a.bin", "docs/readme.txt", "ext/on-disk", "x/y/z"], list.map { |m| m["key"] }

    expected = { "docs/readme.txt" => "hello", "a.bin" => "\x00\xff".b, "x/y/z" => "", "ext/on-disk" => "disk" }
    list.each do |meta|
      content = expected.fetch(meta["key"])
      assert_equal content.bytesize, meta["size"], meta.inspect
      assert_equal Digest::SHA256.hexdigest(content), meta["sha256"], meta.inspect
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, meta["modified_at"])
      assert_in_delta Time.now.to_f, Time.iso8601(meta["modified_at"]).to_f, 60
    end

    # HEAD /blobs — как GET, но без тела.
    response = http.head("/blobs")
    assert_equal "200", response.code
    assert_nil response.body
  end

  def test_delete_blob_over_http
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)

    %w[docs/readme.txt docs/other.txt top].each do |key|
      request = Net::HTTP::Put.new("/blobs/#{key}", "content-type" => "application/octet-stream")
      request.body = key
      assert_equal "201", http.request(request).code
    end

    response = http.delete("/blobs/docs/readme.txt")
    assert_equal "204", response.code
    assert_nil response.body
    assert_nil response["content-type"]
    refute File.exist?(File.join(data_dir, "docs", "readme.txt"))

    assert_equal "404", http.get("/blobs/docs/readme.txt").code
    assert_equal "404", http.delete("/blobs/docs/readme.txt").code
    assert_equal ["docs/other.txt", "top"], JSON.parse(http.get("/blobs").body).map { |m| m["key"] }
    assert_equal "docs/other.txt", http.get("/blobs/docs/other.txt").body

    assert_equal "204", http.delete("/blobs/docs/other.txt").code
    refute File.exist?(File.join(data_dir, "docs")), "empty docs/ should be pruned"
    assert_equal "404", http.delete("/blobs/missing").code
    assert_equal "404", http.delete("/blobs/no/such/dir/file").code
    assert_equal ["top"], JSON.parse(http.get("/blobs").body).map { |m| m["key"] }
  end

  def test_missing_data_dir_fails_fast_with_usage_error
    _out, err, status = Open3.capture3({ "SYNCBOX_DATA_DIR" => nil }, SERVER_BIN)
    assert_equal 2, status.exitstatus
    assert_match(/--data-dir is required/, err)
  end
end
