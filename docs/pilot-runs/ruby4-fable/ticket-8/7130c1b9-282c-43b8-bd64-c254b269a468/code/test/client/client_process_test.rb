# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"

# Runs the real client executable (bin/syncbox) as a child process against the
# real server executable over HTTP — the same surface ./run-client exposes.
class ClientProcessTest < Minitest::Test
  include TestHelpers
  include ServerProcessHelpers

  CLIENT_BIN = File.join(ROOT, "bin", "syncbox")
  RUN_TIMEOUT = 60

  def test_push_uploads_a_tree_then_only_what_changed
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      write(src, "docs/readme.txt", "hello")
      write(src, "docs/img/logo.png", "\x89PNG".b)
      write(src, "sp ace/ü.txt", "")
      write(src, ".hidden", "h")
      big = Random.new(7).bytes(1_500_000)
      write(src, "big.bin", big)

      with_running_server(File.join(dir, "store")) do |port|
        url = "http://127.0.0.1:#{port}"

        stdout, stderr, status = run_client("push", src, "--server", url)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal "", stderr
        assert_equal <<~OUT, stdout
          uploaded .hidden (new, 1 bytes)
          uploaded big.bin (new, 1500000 bytes)
          uploaded docs/img/logo.png (new, 4 bytes)
          uploaded docs/readme.txt (new, 5 bytes)
          uploaded sp ace/ü.txt (new, 0 bytes)
          push done: 5 uploaded, 0 unchanged, 5 file(s) scanned
        OUT
        assert_equal local_hashes(src), remote_hashes(port), "server must hold byte-identical copies"
        assert_equal big, Net::HTTP.get(URI("#{url}/blobs/big.bin")).b
        assert_equal "", Net::HTTP.get(URI("#{url}/blobs/sp%20ace/%C3%BC.txt"))

        # Nothing changed: nothing is sent, and the server's modified_at stays.
        before = remote_list(port)
        stdout, stderr, status = run_client("push", src, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal "push done: 0 uploaded, 5 unchanged, 5 file(s) scanned\n", stdout
        assert_equal before, remote_list(port), "identical files must not be re-uploaded"

        # One changed, one new, one deleted locally (push never deletes).
        write(src, "docs/readme.txt", "hello world")
        write(src, "new.txt", "n")
        File.delete(File.join(src, ".hidden"))
        stdout, _, status = run_client("push", src, "--server", url)
        assert_equal 0, status.exitstatus
        assert_equal <<~OUT, stdout
          uploaded docs/readme.txt (changed, 11 bytes)
          uploaded new.txt (new, 1 bytes)
          push done: 2 uploaded, 3 unchanged, 5 file(s) scanned
        OUT
        assert_equal "hello world", Net::HTTP.get(URI("#{url}/blobs/docs/readme.txt"))
        assert_equal "h", Net::HTTP.get(URI("#{url}/blobs/.hidden")), "push leaves server-only blobs alone"
        assert_equal local_hashes(src), remote_hashes(port).except(".hidden")
      end
    end
  end

  def test_pull_downloads_a_tree_then_only_what_changed_and_keeps_local_only_files
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      write(src, "docs/readme.txt", "hello")
      write(src, "docs/img/logo.png", "\x89PNG".b)
      write(src, "sp ace/ü.txt", "")
      write(src, ".hidden", "h")
      big = Random.new(11).bytes(1_500_000)
      write(src, "big.bin", big)
      FileUtils.mkdir_p(dst)
      write(dst, "local-only.txt", "mine")
      write(dst, "docs/readme.txt", "stale")

      with_running_server(File.join(dir, "store")) do |port|
        url = "http://127.0.0.1:#{port}"
        _, stderr, status = run_client("push", src, "--server", url)
        assert_equal 0, status.exitstatus, stderr

        stdout, stderr, status = run_client("pull", dst, "--server", url)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal "", stderr
        assert_equal <<~OUT, stdout
          downloaded .hidden (new, 1 bytes)
          downloaded big.bin (new, 1500000 bytes)
          downloaded docs/img/logo.png (new, 4 bytes)
          downloaded docs/readme.txt (changed, 5 bytes)
          downloaded sp ace/ü.txt (new, 0 bytes)
          pull done: 5 downloaded, 0 unchanged, 5 blob(s) listed
        OUT
        assert_equal local_hashes(src), local_hashes(dst).except("local-only.txt"), "pulled files must be byte-identical"
        assert_equal "mine", File.read(File.join(dst, "local-only.txt")), "pull leaves local-only files alone"
        assert_equal big, File.binread(File.join(dst, "big.bin"))

        # Nothing changed: nothing is downloaded, local mtimes stay.
        before = mtimes(dst)
        stdout, stderr, status = run_client("pull", dst, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal "pull done: 0 downloaded, 5 unchanged, 5 blob(s) listed\n", stdout
        assert_equal before, mtimes(dst), "identical files must not be rewritten"

        # One changed and one new on the server, one deleted on the server
        # (pull never deletes), one edited locally (pull restores the server's
        # version — it is "different", and pull has no notion of local wins).
        Net::HTTP.start("127.0.0.1", port) do |http|
          http.put("/blobs/docs/readme.txt", "hello world", "content-type" => "application/octet-stream")
          http.put("/blobs/new.txt", "n", "content-type" => "application/octet-stream")
          http.delete("/blobs/.hidden")
        end
        write(dst, "sp ace/ü.txt", "edited locally")
        stdout, _, status = run_client("pull", dst, "--server", url)
        assert_equal 0, status.exitstatus
        assert_equal <<~OUT, stdout
          downloaded docs/readme.txt (changed, 11 bytes)
          downloaded new.txt (new, 1 bytes)
          downloaded sp ace/ü.txt (changed, 0 bytes)
          pull done: 3 downloaded, 2 unchanged, 5 blob(s) listed
        OUT
        assert_equal "hello world", File.read(File.join(dst, "docs/readme.txt"))
        assert_equal "n", File.read(File.join(dst, "new.txt"))
        assert_equal "", File.read(File.join(dst, "sp ace/ü.txt"))
        assert_equal "h", File.read(File.join(dst, ".hidden")), "pull never deletes local files"
        assert_equal remote_hashes(port), local_hashes(dst).except("local-only.txt", ".hidden")
      end
    end
  end

  def test_pull_into_an_empty_directory_mirrors_the_server_and_round_trips_with_push
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      write(src, "a/b/c/deep.txt", "deep")
      write(src, "top.txt", "top")
      FileUtils.mkdir_p(dst)

      with_running_server(File.join(dir, "store")) do |port|
        env = { "SYNCBOX_SERVER" => "http://localhost:#{port}/" }
        _, stderr, status = run_client("push", "src", env: env, chdir: dir)
        assert_equal 0, status.exitstatus, stderr
        stdout, stderr, status = run_client("pull", "dst", env: env, chdir: dir)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal local_hashes(src), local_hashes(dst)
        assert_equal [], Dir.glob("**/.syncbox-tmp-*", File::FNM_DOTMATCH, base: dst), "no staging files left behind"
      end
    end
  end

  def test_pull_refuses_to_overwrite_a_directory_and_reports_it
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      write(src, "x", "file on the server")
      FileUtils.mkdir_p(File.join(dst, "x"))
      with_running_server(File.join(dir, "store")) do |port|
        url = "http://127.0.0.1:#{port}"
        run_client("push", src, "--server", url)
        stdout, stderr, status = run_client("pull", dst, "--server", url)
        assert_equal 1, status.exitstatus
        assert_equal "", stdout
        assert_equal "syncbox: x: a directory is in the way of the file\n", stderr
        assert File.directory?(File.join(dst, "x"))
      end
    end
  end

  def test_pull_from_an_unreachable_server_fails_fast_with_a_clear_message
    with_tmpdir do |dir|
      port = free_port
      stdout, stderr, status = run_client("pull", dir, "--server", "http://127.0.0.1:#{port}")
      assert_equal 1, status.exitstatus
      assert_equal "", stdout
      assert_match(/\Asyncbox: cannot reach server at http:\/\/127\.0\.0\.1:#{port}: /, stderr)
      assert_match(/refused/i, stderr)
      assert_equal [], Dir.children(dir)
    end
  end

  def test_pull_into_a_missing_directory_fails
    with_tmpdir do |dir|
      _, stderr, status = run_client("pull", File.join(dir, "nope"), "--server", "http://127.0.0.1:1")
      assert_equal 1, status.exitstatus
      assert_match(/syncbox: not a directory: .*nope/, stderr)
    end
  end

  def test_server_url_from_environment_relative_dir_and_trailing_slash
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      write(src, "f.txt", "f")

      with_running_server(File.join(dir, "store")) do |port|
        stdout, stderr, status = run_client("push", "src", env: { "SYNCBOX_SERVER" => "http://localhost:#{port}/" }, chdir: dir)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal ["f.txt"], remote_hashes(port).keys
      end
    end
  end

  def test_symlinks_are_skipped_with_a_warning_but_the_push_succeeds
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      write(src, "f.txt", "f")
      File.symlink("/etc/passwd", File.join(src, "passwd-link"))

      with_running_server(File.join(dir, "store")) do |port|
        stdout, stderr, status = run_client("push", src, "--server", "http://127.0.0.1:#{port}")
        assert_equal 0, status.exitstatus, stderr
        assert_equal "syncbox: warning: skipping passwd-link: symbolic links are not uploaded\n", stderr
        assert_match(/push done: 1 uploaded/, stdout)
        assert_equal ["f.txt"], remote_hashes(port).keys
      end
    end
  end

  def test_unreachable_server_fails_fast_with_a_clear_message
    with_tmpdir do |dir|
      write(dir, "f.txt", "f")
      port = free_port
      stdout, stderr, status = run_client("push", dir, "--server", "http://127.0.0.1:#{port}")
      assert_equal 1, status.exitstatus
      assert_equal "", stdout
      assert_match(/\Asyncbox: cannot reach server at http:\/\/127\.0\.0\.1:#{port}: /, stderr)
      assert_match(/refused/i, stderr)
    end
  end

  def test_server_answering_outside_the_contract_is_reported
    with_tmpdir do |dir|
      write(File.join(dir, "src"), "f.txt", "f")
      with_running_server(File.join(dir, "store")) do |port|
        _, stderr, status = run_client("push", File.join(dir, "src"), "--server", "http://127.0.0.1:#{port}/healthz")
        assert_equal 1, status.exitstatus
        assert_match(/syncbox: server answered 404 Not Found to GET \/healthz\/blobs/, stderr)
      end
    end
  end

  def test_missing_directory_fails
    with_tmpdir do |dir|
      _, stderr, status = run_client("push", File.join(dir, "nope"), "--server", "http://127.0.0.1:1")
      assert_equal 1, status.exitstatus
      assert_match(/syncbox: not a directory: .*nope/, stderr)
    end
  end

  def test_usage_errors_exit_2_with_usage
    stdout, stderr, status = run_client("push", "dir")
    assert_equal 2, status.exitstatus
    assert_equal "", stdout
    assert_match(/syncbox: --server is required \(or set SYNCBOX_SERVER\)/, stderr)
    assert_match(/Usage: syncbox <push\|pull\|sync\|status> <dir> --server <url>/, stderr)

    _, stderr, status = run_client("fetch", "dir", "--server", "http://h")
    assert_equal 2, status.exitstatus
    assert_match(/unknown command "fetch"/, stderr)

    _, stderr, status = run_client
    assert_equal 2, status.exitstatus
    assert_match(/missing command/, stderr)

    _, stderr, status = run_client("push", "dir", "--server", "127.0.0.1:8080")
    assert_equal 2, status.exitstatus
    assert_match(/invalid server URL/, stderr)
  end

  def test_help_prints_usage_and_exits_zero
    stdout, stderr, status = run_client("--help")
    assert_equal 0, status.exitstatus
    assert_equal "", stderr
    assert_match(/Usage: syncbox <push\|pull\|sync\|status> <dir> --server <url>/, stdout)
    assert_match(/--server URL/, stdout)
  end

  def test_sync_and_status_are_accepted_but_report_not_implemented
    with_tmpdir do |dir|
      { "status" => "ticket 9", "sync" => "ticket 10" }.each do |command, ticket|
        stdout, stderr, status = run_client(command, dir, "--server", "http://127.0.0.1:1")
        assert_equal 1, status.exitstatus, command
        assert_equal "", stdout
        assert_equal "syncbox: '#{command}' is not implemented yet (planned for #{ticket}); " \
                     "only 'push' and 'pull' are available in this version\n", stderr
      end
    end
  end

  private

  def run_client(*args, env: {}, chdir: nil)
    opts = chdir ? { chdir: chdir } : {}
    Open3.popen3(clean_env(env), CLIENT_BIN, *args, opts) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      unless wait_thr.join(RUN_TIMEOUT)
        Process.kill("KILL", wait_thr.pid)
        flunk "#{CLIENT_BIN} #{args.join(' ')} did not exit within #{RUN_TIMEOUT}s"
      end
      [out_reader.value.force_encoding(Encoding::UTF_8), err_reader.value.force_encoding(Encoding::UTF_8), wait_thr.value]
    end
  end

  def remote_list(port)
    JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}/blobs")))
  end

  def remote_hashes(port)
    remote_list(port).to_h { |m| [m["key"], m["sha256"]] }
  end

  def mtimes(dir)
    local_hashes(dir).keys.to_h { |rel| [rel, File.mtime(File.join(dir, rel))] }
  end
  def local_hashes(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir)
       .select { |rel| File.file?(File.join(dir, rel)) }
       .to_h { |rel| [rel, Digest::SHA256.file(File.join(dir, rel)).hexdigest] }
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
