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

  def test_missing_data_dir_fails_fast_with_usage_error
    _out, err, status = Open3.capture3({ "SYNCBOX_DATA_DIR" => nil }, SERVER_BIN)
    assert_equal 2, status.exitstatus
    assert_match(/--data-dir is required/, err)
  end
end
