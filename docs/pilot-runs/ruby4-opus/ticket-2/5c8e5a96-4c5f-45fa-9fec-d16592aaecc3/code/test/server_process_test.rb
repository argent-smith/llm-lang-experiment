# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "net/http"
require "socket"

# Runs bin/syncbox-server as a separate process, the way run-server does
# inside the container, and talks to it over real HTTP.
class ServerProcessTest < Minitest::Test
  BIN = File.expand_path("../bin/syncbox-server", __dir__)
  BOOT_TIMEOUT = 20

  def setup
    @tmp = Dir.mktmpdir
    @port = free_port
  end

  def teardown
    stop_server
    FileUtils.rm_rf(@tmp)
  end

  def test_serves_healthz_with_flags
    data_dir = File.join(@tmp, "data")
    start_server("--data-dir", data_dir, "--port", @port.to_s)

    assert_equal "200", get("/healthz").code
    assert File.directory?(data_dir), "data directory should be created"
  end

  def test_serves_healthz_with_environment_variables
    start_server(env: { "SYNCBOX_DATA_DIR" => @tmp, "SYNCBOX_PORT" => @port.to_s })

    assert_equal "200", get("/healthz").code
    assert_equal "200", Net::HTTP.start("127.0.0.1", @port) { |http| http.head("/healthz") }.code
  end

  def test_blob_endpoints_answer_within_contract
    start_server("--data-dir", @tmp, "--port", @port.to_s)

    list = get("/blobs")

    assert_equal "200", list.code
    assert_equal [], JSON.parse(list.body)
    assert_equal "201", put("/blobs/0", "").code
    assert_equal "201", put("/blobs/docs%2Freadme.txt", "hello").code
    ["/blobs/..%2Fescape", "/blobs/%ED%A0%80", "/blobs/a%00b", "/blobs/0/sub", "/blobs/#{'b/' * 2100}c"].each do |path|
      assert_equal "400", put(path, "x").code, path[0, 40]
    end
    assert_equal %w[0 docs/readme.txt], JSON.parse(get("/blobs").body).map { |blob| blob["key"] }
    refute File.exist?(File.join(@tmp, "escape"))
  end

  def test_put_then_get_blob_round_trips_bytes
    start_server("--data-dir", @tmp, "--port", @port.to_s)
    content = Random.new(42).bytes(300_000)

    response = put("/blobs/docs/data.bin", content)

    assert_equal "201", response.code
    assert_equal({ "key" => "docs/data.bin", "sha256" => Digest::SHA256.hexdigest(content), "size" => content.bytesize },
                 JSON.parse(response.body))
    blob = get("/blobs/docs/data.bin")

    assert_equal "200", blob.code
    assert_equal content, blob.body.b
    assert_equal "404", get("/blobs/docs/missing.bin").code
  end

  def test_stops_cleanly_on_sigterm
    start_server("--data-dir", @tmp, "--port", @port.to_s)
    Process.kill("TERM", @pid)

    assert_predicate wait_for_exit, :success?
  end

  def test_missing_data_dir_is_a_usage_error
    out, status = run_to_completion("--port", @port.to_s)

    assert_equal 2, status.exitstatus
    assert_match(/data directory is required/, out)
  end

  def test_invalid_port_is_a_usage_error
    out, status = run_to_completion("--data-dir", @tmp, "--port", "99999")

    assert_equal 2, status.exitstatus
    assert_match(/invalid port/, out)
  end

  def test_port_in_use_is_reported
    blocker = TCPServer.new("0.0.0.0", @port)
    out, status = run_to_completion("--data-dir", @tmp, "--port", @port.to_s)

    refute_predicate status, :success?
    assert_match(/#{@port}/, out)
  ensure
    blocker&.close
  end

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def start_server(*args, env: {})
    @log = File.join(@tmp, "server.log")
    @pid = Process.spawn(clean_env.merge(env), BIN, *args, %i[out err] => @log)
    deadline = Time.now + BOOT_TIMEOUT
    loop do
      return if (get("/healthz") rescue nil)
      flunk "server exited during boot:\n#{File.read(@log)}" if Process.wait(@pid, Process::WNOHANG)
      flunk "server did not boot in #{BOOT_TIMEOUT}s:\n#{File.read(@log)}" if Time.now > deadline
      sleep 0.1
    end
  end

  def stop_server
    return unless @pid

    Process.kill("KILL", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def wait_for_exit(timeout = 10)
    deadline = Time.now + timeout
    until (result = Process.wait2(@pid, Process::WNOHANG))
      flunk "server did not exit within #{timeout}s" if Time.now > deadline
      sleep 0.1
    end
    @pid = nil
    result[1]
  end

  def run_to_completion(*args)
    log = File.join(@tmp, "run.log")
    pid = Process.spawn(clean_env, BIN, *args, %i[out err] => log)
    _, status = Process.wait2(pid)
    [File.read(log), status]
  end

  # Ignore SYNCBOX_* settings that may be set in the test container.
  def clean_env
    { "SYNCBOX_DATA_DIR" => nil, "SYNCBOX_PORT" => nil }
  end

  def get(path)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 1, read_timeout: 5) { |http| http.get(path) }
  end

  def put(path, body)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 1, read_timeout: 5) do |http|
      http.put(path, body, "content-type" => "application/octet-stream")
    end
  end
end
