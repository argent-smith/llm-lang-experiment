# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "stringio"

# The Runner in-process against FakeHttpServer: exit codes and stderr for the
# spec's "Exit codes and errors" section, with the Api's timeouts shortened
# through +build_api+ so that a server that never answers is caught in
# seconds rather than the CLI's fixed read timeout.
class ClientRunnerTest < Minitest::Test
  include TestHelpers
  include ServerProcessHelpers

  Runner = Syncbox::Client::Runner
  Api = Syncbox::Client::Api

  def run_runner(*argv, read_timeout: Api::READ_TIMEOUT, open_timeout: Api::OPEN_TIMEOUT)
    out = StringIO.new
    err = StringIO.new
    build_api = ->(url) { Api.new(url, read_timeout: read_timeout, open_timeout: open_timeout) }
    code = Runner.new(argv, env: {}, out: out, err: err, build_api: build_api).run
    [code, out.string, err.string]
  end

  def test_exit_codes_are_distinct_constants
    assert_equal [0, 1, 2, 3, 130],
                 [Runner::EXIT_OK, Runner::EXIT_FAILURE, Runner::EXIT_USAGE, Runner::EXIT_PARTIAL, Runner::EXIT_INTERRUPTED]
  end

  # Spec: server unavailable (timeout) → clear message on stderr, non-zero
  # exit, no hang. Here for every command: the server accepts the connection,
  # reads GET /blobs and never answers.
  def test_a_server_that_never_answers_is_reported_as_a_timeout_and_exits_1_without_hanging
    with_tmpdir do |dir|
      write(dir, "f.txt", "f")
      %w[push pull status sync].each do |command|
        FakeHttpServer.open(hang: :all) do |server|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          code, out, err = run_runner(command, dir, "--server", server.url, read_timeout: 1)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          assert_operator elapsed, :<, 10, "#{command} must give up after the read timeout"
          assert_equal 1, code, command
          assert_equal "", out, command
          assert_equal "syncbox: cannot reach server at #{server.url}: no response from 127.0.0.1:#{server.port} within 1s " \
                       "(read timeout) (GET /blobs)\n", err, command
          assert_equal [["GET", "/blobs"]], server.requests
        end
      end
      assert_equal ["f.txt"], Dir.children(dir), "nothing is written when the server never answers"
    end
  end

  # The same at the connect stage: the address never completes the
  # connection, so the open timeout is what ends the wait.
  def test_a_server_that_never_completes_the_connection_is_reported_as_a_timeout_and_exits_1_without_hanging
    with_tmpdir do |dir|
      write(dir, "f.txt", "f")
      with_black_hole_port do |port|
        %w[push pull status sync].each do |command|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          code, out, err = run_runner(command, dir, "--server", "http://127.0.0.1:#{port}", open_timeout: 1)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          assert_operator elapsed, :<, 10, "#{command} must give up after the open timeout"
          assert_equal 1, code, command
          assert_equal "", out, command
          assert_equal "syncbox: cannot reach server at http://127.0.0.1:#{port}: connection to 127.0.0.1:#{port} " \
                       "timed out after 1s (GET /blobs)\n", err, command
        end
      end
      assert_equal ["f.txt"], Dir.children(dir), "nothing is written when the server cannot be connected to"
    end
  end

  def test_a_server_that_stops_answering_mid_run_is_reported_as_a_timeout_on_that_file_and_the_run_goes_on
    with_tmpdir do |dir|
      write(dir, "a.txt", "A")
      write(dir, "slow.txt", "S")
      write(dir, "z.txt", "Z")
      FakeHttpServer.open(hang: ["PUT /blobs/slow.txt"]) do |server|
        code, out, err = run_runner("push", dir, "--server", server.url, read_timeout: 1)
        assert_equal 3, code
        assert_equal "uploaded a.txt (new, 1 bytes)\nuploaded z.txt (new, 1 bytes)\n" \
                     "push done: 2 uploaded, 0 unchanged, 1 failed, 3 file(s) scanned\n", out
        assert_equal <<~ERR, err
          syncbox: failed slow.txt: cannot reach server at #{server.url}: no response from 127.0.0.1:#{server.port} within 1s (read timeout) (PUT /blobs/slow.txt)
          syncbox: push incomplete: 1 of 3 file(s) failed
          syncbox:   slow.txt: cannot reach server at #{server.url}: no response from 127.0.0.1:#{server.port} within 1s (read timeout) (PUT /blobs/slow.txt)
        ERR
        assert_equal({ "a.txt" => "A", "z.txt" => "Z" }, server.blobs)
      end
    end
  end

  # Spec: server unavailable (network error) → clear message, non-zero exit.
  def test_connection_refused_exits_1_with_the_cause
    with_tmpdir do |dir|
      port = free_port
      code, out, err = run_runner("pull", dir, "--server", "http://127.0.0.1:#{port}")
      assert_equal 1, code
      assert_equal "", out
      assert_equal "syncbox: cannot reach server at http://127.0.0.1:#{port}: connection refused by 127.0.0.1:#{port} " \
                   "(is the server running there?) (GET /blobs)\n", err
    end
  end

  def test_an_unknown_host_exits_1_with_the_cause
    with_tmpdir do |dir|
      code, out, err = run_runner("status", dir, "--server", "http://no-such-host.invalid:1", open_timeout: 5)
      assert_equal 1, code
      assert_equal "", out
      assert_match(/\Asyncbox: cannot reach server at http:\/\/no-such-host\.invalid:1: (cannot resolve host name "no-such-host\.invalid" \(.+\)|connection to no-such-host\.invalid:1 timed out after 5s) \(GET \/blobs\)\n\z/, err)
    end
  end

  # Spec: partial failure → the rest is processed, a report at the end,
  # non-zero exit. The Runner tells it apart from "could not run" with 3.
  def test_a_partial_failure_exits_3_a_complete_run_exits_0
    with_tmpdir do |dir|
      write(dir, "a.txt", "A")
      write(dir, "b.txt", "B")
      FakeHttpServer.open(fail: { "b.txt" => 500 }) do |server|
        code, out, err = run_runner("push", dir, "--server", server.url)
        assert_equal 3, code
        assert_match(/push done: 1 uploaded, 0 unchanged, 1 failed, 2 file\(s\) scanned/, out)
        assert_match(/^syncbox: push incomplete: 1 of 2 file\(s\) failed\nsyncbox:   b\.txt: server answered 500/, err)

        server.instance_variable_get(:@fail).clear
        code, out, err = run_runner("push", dir, "--server", server.url)
        assert_equal 0, code
        assert_equal "uploaded b.txt (new, 1 bytes)\npush done: 1 uploaded, 1 unchanged, 2 file(s) scanned\n", out
        assert_equal "", err
      end
    end
  end

  def test_a_server_lost_mid_run_exits_1_after_the_report
    with_tmpdir do |dir|
      FakeHttpServer.open(blobs: { "a.txt" => "a", "b.txt" => "b", "c.txt" => "c", "d.txt" => "d" }, stop_after: 1) do |server|
        # The listing is served, then the server is gone; every GET is refused.
        code, out, err = run_runner("pull", dir, "--server", server.url)
        assert_equal 1, code
        assert_equal "", out
        assert_match(/\Asyncbox: failed a\.txt: cannot reach server .*connection refused.*\(GET \/blobs\/a\.txt\)\n/, err)
        assert_match(/^syncbox: pull aborted: 2 of 4 file\(s\) failed, 2 not attempted\n/, err)
        assert_match(/^syncbox: server unreachable: cannot reach server .*; giving up after 2 consecutive requests failed \(2 file\(s\) not attempted/, err)
        assert_equal [], Dir.children(dir)
      end
    end
  end

  private

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
