# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

# Runs bin/syncbox as a real process, as run-client does inside the container.
class ClientProcessTest < Minitest::Test
  CLIENT_BIN = File.expand_path("../bin/syncbox", __dir__)

  def setup
    @tmp = Dir.mktmpdir
    @dir = File.join(@tmp, "local")
    FileUtils.mkdir_p(File.join(@dir, "docs"))
    File.write(File.join(@dir, "docs", "readme.txt"), "hello")
    config = Syncbox::Server::Config.new(data_dir: File.join(@tmp, "data"), port: 8080)
    @server = TestHTTPServer.new(Syncbox::Server::Runner.build_app(config))
  end

  def teardown
    @server.stop
    FileUtils.remove_entry(@tmp)
  end

  def test_push_with_server_flag
    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => nil }, CLIENT_BIN, "push", @dir, "--server", @server.url)
    assert_equal 0, status.exitstatus, err
    assert_equal "uploaded docs/readme.txt\npush: 1 uploaded, 0 unchanged\n", out
    assert_equal ["docs/readme.txt"], JSON.parse(Net::HTTP.get(URI("#{@server.url}/blobs"))).map { |e| e["key"] }
  end

  def test_push_with_server_from_environment
    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => @server.url }, CLIENT_BIN, "push", @dir)
    assert_equal 0, status.exitstatus, err
    assert_match(/push: 1 uploaded/, out)
  end

  def test_pull_with_server_flag
    pulled = File.join(@tmp, "pulled")
    Dir.mkdir(pulled)
    assert_equal 0, Open3.capture3(CLIENT_BIN, "push", @dir, "--server", @server.url).last.exitstatus

    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => nil }, CLIENT_BIN, "pull", pulled, "--server", @server.url)
    assert_equal 0, status.exitstatus, err
    assert_equal "downloaded docs/readme.txt\npull: 1 downloaded, 0 unchanged\n", out
    assert_equal "hello", File.read(File.join(pulled, "docs", "readme.txt"))
  end

  def test_pull_with_server_from_environment
    pulled = File.join(@tmp, "pulled")
    Dir.mkdir(pulled)
    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => @server.url }, CLIENT_BIN, "pull", pulled)
    assert_equal 0, status.exitstatus, err
    assert_equal "pull: 0 downloaded, 0 unchanged\n", out
  end

  def test_missing_server_is_a_usage_error
    _out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => nil }, CLIENT_BIN, "push", @dir)
    assert_equal 2, status.exitstatus
    assert_match(/--server/, err)
  end

  def test_status_with_server_flag
    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => nil }, CLIENT_BIN, "status", @dir, "--server", @server.url)
    assert_equal 0, status.exitstatus, err
    assert_equal "upload    new      docs/readme.txt\nstatus: 1 to upload, 0 to download, 0 unchanged\n", out
    assert_equal [], JSON.parse(Net::HTTP.get(URI("#{@server.url}/blobs")))
  end

  def test_status_with_server_from_environment
    assert_equal 0, Open3.capture3(CLIENT_BIN, "push", @dir, "--server", @server.url).last.exitstatus
    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => @server.url }, CLIENT_BIN, "status", @dir)
    assert_equal 0, status.exitstatus, err
    assert_equal "status: in sync, 1 unchanged\n", out
  end

  def test_sync_with_server_flag
    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => nil }, CLIENT_BIN, "sync", @dir, "--server", @server.url)
    assert_equal 0, status.exitstatus, err
    assert_equal "uploaded docs/readme.txt\nsync: 1 uploaded, 0 downloaded, 0 unchanged, 0 conflicts\n", out
    assert_equal ["docs/readme.txt"], JSON.parse(Net::HTTP.get(URI("#{@server.url}/blobs"))).map { |e| e["key"] }
  end

  def test_sync_with_server_from_environment
    other = File.join(@tmp, "other")
    Dir.mkdir(other)
    assert_equal 0, Open3.capture3(CLIENT_BIN, "push", @dir, "--server", @server.url).last.exitstatus

    out, err, status = Open3.capture3({ "SYNCBOX_SERVER" => @server.url }, CLIENT_BIN, "sync", other)
    assert_equal 0, status.exitstatus, err
    assert_equal "downloaded docs/readme.txt\nsync: 0 uploaded, 1 downloaded, 0 unchanged, 0 conflicts\n", out
    assert_equal "hello", File.read(File.join(other, "docs", "readme.txt"))
  end

  def test_partial_failure_exits_non_zero_with_a_report
    File.write(File.join(@dir, "other.txt"), "other")
    server_app = Syncbox::Server::Runner.build_app(
      Syncbox::Server::Config.new(data_dir: File.join(@tmp, "data2"), port: 8080)
    )
    failing = lambda do |env|
      if env["REQUEST_METHOD"] == "PUT" && env["PATH_INFO"] == "/blobs/docs/readme.txt"
        [500, { "content-type" => "text/plain" }, ["disk on fire\n"]]
      else
        server_app.call(env)
      end
    end
    TestHTTPServer.open(failing) do |broken|
      out, err, status = Open3.capture3(CLIENT_BIN, "push", @dir, "--server", broken.url)
      assert_equal 1, status.exitstatus
      assert_equal "uploaded other.txt\npush: 1 uploaded, 0 unchanged, 1 failed\n", out
      assert_equal "syncbox: push failed for 1 file:\n  server answered PUT docs/readme.txt with HTTP 500: disk on fire\n", err
      assert_equal ["other.txt"], JSON.parse(Net::HTTP.get(URI("#{broken.url}/blobs"))).map { |e| e["key"] }
    end
  end

  def test_sync_with_unreachable_server_exits_non_zero_with_a_message
    port = @server.port
    @server.stop
    out, err, status = Open3.capture3(CLIENT_BIN, "sync", @dir, "--server", "http://127.0.0.1:#{port}")
    assert_equal 1, status.exitstatus
    assert_match(/\Asyncbox: cannot reach server/, err)
    assert_empty out
  end
end
