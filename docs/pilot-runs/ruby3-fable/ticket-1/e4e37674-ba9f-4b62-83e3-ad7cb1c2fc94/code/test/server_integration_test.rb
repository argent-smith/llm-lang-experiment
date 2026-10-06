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

  def test_missing_data_dir_fails_fast_with_usage_error
    _out, err, status = Open3.capture3({ "SYNCBOX_DATA_DIR" => nil }, SERVER_BIN)
    assert_equal 2, status.exitstatus
    assert_match(/--data-dir is required/, err)
  end
end
