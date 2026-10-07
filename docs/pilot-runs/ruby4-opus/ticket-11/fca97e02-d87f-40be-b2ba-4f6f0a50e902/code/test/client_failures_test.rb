# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "socket"
require "stringio"
require "support/faulty_server"

# Network errors and partial failures ("Exit codes and errors" in
# SYNCBOX-SPEC.md), end to end: bin/syncbox runs as a separate process, the
# way run-client runs it in the container, against the real server
# application with faults injected for some keys (FaultyServer). Timeouts are
# tested through Client::CLI in-process, with short timeouts rather than the
# real ones.
class ClientFailuresTest < Minitest::Test
  CLIENT_BIN = File.expand_path("../bin/syncbox", __dir__)
  COMMANDS = %w[push pull status sync].freeze

  def setup
    @tmp = Dir.mktmpdir
    @dir = File.join(@tmp, "local")
    Dir.mkdir(@dir)
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def test_refused_connection_fails_every_command_fast_with_a_message
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    write("f", "x")

    COMMANDS.each do |command|
      started = Time.now
      out, err, status = client(command, @dir, "--server", "http://127.0.0.1:#{port}")

      assert_equal 1, status.exitstatus, command
      assert_equal "", out, command
      assert_equal "syncbox: cannot list blobs: server http://127.0.0.1:#{port} is unreachable: connection refused\n", err
      assert_operator Time.now - started, :<, 15, command
    end
    assert_equal %w[f], Dir.children(@dir)
  end

  def test_unresolvable_host_name_fails_with_a_message
    out, err, status = client("push", @dir, "--server", "http://no-such-host.invalid:8080")

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot list blobs: server http://no-such-host\.invalid:8080 is unreachable: cannot resolve host name no-such-host\.invalid \(.+\)\n\z}, err)
  end

  def test_server_that_accepts_but_never_answers_times_out
    server = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{server.addr[1]}"
    write("f", "x")

    COMMANDS.each do |command|
      started = Time.now
      code, out, err = cli(command, @dir, "--server", url, timeouts: { read_timeout: 1 })

      assert_equal 1, code, command
      assert_equal "", out, command
      assert_equal "syncbox: cannot list blobs: server #{url} is unreachable: no response within 1s\n", err
      assert_operator Time.now - started, :<, 5, command
    end
  ensure
    server&.close
  end

  def test_push_with_a_failing_key_uploads_the_rest_and_reports_it
    start_server
    @server.fail("PUT", "b")
    files = { "a" => "a", "b" => "b", "c/d" => "d", "e" => "e" }
    files.each { |key, content| write(key, content) }

    out, err, status = client("push", @dir, "--server", @server.url)

    assert_equal 1, status.exitstatus
    assert_equal "uploaded a\nuploaded c/d\nuploaded e\npush: 3 uploaded, 0 up to date, 1 failed\n", out
    assert_equal "syncbox: push incomplete: 1 failed:\n  cannot upload b: server answered 500 injected failure\n", err
    assert_equal %w[a c/d e], stored.keys
    files.except("b").each { |key, content| assert_equal Digest::SHA256.hexdigest(content), stored[key]["sha256"], key }

    # Nothing else is uploaded again once the server takes b too.
    @server.fail("PUT", "b", nil)
    out, err, status = client("push", @dir, "--server", @server.url)

    assert_predicate status, :success?, err
    assert_equal "uploaded b\npush: 1 uploaded, 3 up to date\n", out
  end

  def test_push_with_a_connection_dropped_on_one_key_uploads_the_rest
    start_server
    @server.fail("PUT", "b", :drop)
    %w[a b c].each { |key| write(key, key) }

    out, err, status = client("push", @dir, "--server", @server.url)

    assert_equal 1, status.exitstatus
    assert_equal "uploaded a\nuploaded c\npush: 2 uploaded, 0 up to date, 1 failed\n", out
    assert_match(%r{\Asyncbox: push incomplete: 1 failed:\n  cannot upload b: connection to server #{Regexp.escape(@server.url)} failed: .+\n\z},
                 err)
    assert_equal %w[a c], stored.keys
  end

  def test_push_with_an_unreadable_file_uploads_the_rest
    skip "root ignores permission bits" if Process.uid.zero?
    start_server
    %w[a b c].each { |key| write(key, key) }
    File.chmod(0o000, File.join(@dir, "b"))

    out, err, status = client("push", @dir, "--server", @server.url)

    assert_equal 1, status.exitstatus
    assert_equal "uploaded a\nuploaded c\npush: 2 uploaded, 0 up to date, 1 failed\n", out
    assert_equal "syncbox: push incomplete: 1 failed:\n  cannot read b: Permission denied\n", err
    assert_equal %w[a c], stored.keys
  end

  def test_pull_with_a_failing_download_downloads_the_rest_and_reports_it
    start_server
    { "a" => "a", "b" => "b", "c" => "c", "d/e" => "e" }.each { |key, content| put(key, content) }
    write("b", "old b")
    @server.fail("GET", "b")
    @server.fail("GET", "c", :drop)

    out, err, status = client("pull", @dir, "--server", @server.url)

    assert_equal 1, status.exitstatus
    assert_equal "downloaded a\ndownloaded d/e\npull: 2 downloaded, 0 up to date, 2 failed\n", out
    assert_match(/\Asyncbox: pull incomplete: 2 failed:\n/, err)
    assert_includes err, "\n  cannot download b: server answered 500 injected failure\n"
    assert_match(%r{\n  cannot download c: connection to server #{Regexp.escape(@server.url)} failed: .+\n\z}, err)
    assert_equal({ "a" => "a", "b" => "old b", "d/e" => "e" }, local_files)
    assert_equal %w[a b d], Dir.children(@dir).sort, "no temporary file is left behind"
  end

  def test_sync_with_failures_in_both_directions_transfers_the_rest
    start_server
    write("up-ok", "u")
    write("up-fails", "u")
    put("down-ok", "d")
    put("down-fails", "d")
    @server.fail("PUT", "up-fails")
    @server.fail("GET", "down-fails")

    out, err, status = client("sync", @dir, "--server", @server.url)

    assert_equal 1, status.exitstatus
    assert_equal "downloaded down-ok\nuploaded up-ok\nsync: 1 uploaded, 1 downloaded, 0 up to date, 2 failed\n", out
    assert_equal "syncbox: sync incomplete: 2 failed:\n" \
                 "  cannot download down-fails: server answered 500 injected failure\n" \
                 "  cannot upload up-fails: server answered 500 injected failure\n", err
    assert_equal %w[down-fails down-ok up-ok], stored.keys
    assert_equal({ "down-ok" => "d", "up-fails" => "u", "up-ok" => "u" }, local_files)

    # The next sync picks up where this one failed.
    @server.fail("PUT", "up-fails", nil)
    @server.fail("GET", "down-fails", nil)
    out, err, status = client("sync", @dir, "--server", @server.url)

    assert_predicate status, :success?, err
    assert_equal "downloaded down-fails\nuploaded up-fails\nsync: 1 uploaded, 1 downloaded, 2 up to date\n", out
  end

  def test_status_with_an_unreadable_file_reports_the_rest
    skip "root ignores permission bits" if Process.uid.zero?
    start_server
    put("a", "server")
    write("a", "local!") # as large as the blob: it has to be read to tell
    write("b", "b")
    File.chmod(0o000, File.join(@dir, "a"))

    out, err, status = client("status", @dir, "--server", @server.url)

    assert_equal 1, status.exitstatus
    assert_equal "upload (not on server): b\nstatus: 1 to upload, 0 to download, 0 up to date, 1 failed\n", out
    assert_equal "syncbox: status incomplete: 1 failed:\n  cannot read a: Permission denied\n", err
  end

  def test_server_that_stops_answering_midway_stops_the_transfers
    start_server
    @server.fail("PUT", "b", :hang)
    %w[a b c d].each { |key| write(key, key) }
    started = Time.now

    code, out, err = cli("push", @dir, "--server", @server.url, timeouts: { read_timeout: 1 })

    assert_equal 1, code
    assert_operator Time.now - started, :<, 5
    assert_equal "uploaded a\npush: 1 uploaded, 0 up to date, 1 failed, 2 not attempted\n", out
    assert_equal "syncbox: push incomplete: 1 failed, 2 not attempted (server unreachable):\n" \
                 "  cannot upload b: server #{@server.url} is unreachable: no response within 1s\n", err
    assert_equal %w[a], stored.keys
  end

  private

  def start_server
    @server = FaultyServer.new(File.join(@tmp, "data"))
  end

  def client(*args)
    Open3.capture3({ "SYNCBOX_SERVER" => nil }, CLIENT_BIN, *args)
  end

  # Runs the client in-process: [exit code, stdout, stderr].
  def cli(*argv, timeouts:)
    out = StringIO.new
    err = StringIO.new
    code = Syncbox::Client::CLI.run(argv, env: {}, out: out, err: err, timeouts: timeouts)
    [code, out.string, err.string]
  end

  def write(key, content)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def put(key, content)
    Net::HTTP.start("127.0.0.1", @server.port) { |http| http.put("/blobs/#{key}", content) }
  end

  # The server's blob list: {key => metadata}.
  def stored
    body = Net::HTTP.start("127.0.0.1", @server.port) { |http| http.get("/blobs") }.body
    JSON.parse(body).to_h { |blob| [blob["key"], blob] }
  end

  # The user's regular files under the directory: {key => content}.
  def local_files
    Dir.glob("**/*", base: @dir).select { |key| File.file?(File.join(@dir, key)) }.to_h do |key|
      [key, File.binread(File.join(@dir, key))]
    end
  end
end
