# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "time"

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

  def test_status_reports_both_directions_and_changes_nothing_on_either_side
    with_tmpdir do |dir|
      src = File.join(dir, "src")
      dst = File.join(dir, "dst")
      write(src, "same.txt", "same")
      write(src, "docs/changed.txt", "server version")
      write(src, "sp ace/ü.txt", "remote only")
      write(src, ".hidden", "h")
      write(dst, "same.txt", "same")
      write(dst, "docs/changed.txt", "local version!")
      write(dst, "local-only.txt", "mine")
      write(dst, "new/deep/file.bin", "\x00\x01".b)

      with_running_server(File.join(dir, "store")) do |port|
        url = "http://127.0.0.1:#{port}"
        _, stderr, status = run_client("push", src, "--server", url)
        assert_equal 0, status.exitstatus, stderr

        server_before = remote_list(port)
        local_before = snapshot(dst)

        stdout, stderr, status = run_client("status", dst, "--server", url)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal "", stderr
        assert_equal <<~OUT, stdout
          upload    local-only.txt  (missing on server, 4 bytes)
          upload    new/deep/file.bin  (missing on server, 2 bytes)
          download  .hidden  (missing locally, 1 bytes)
          download  sp ace/ü.txt  (missing locally, 11 bytes)
          differs   docs/changed.txt  (local 14 bytes, server 14 bytes; push would upload, pull would download)
          status: 2 to upload, 2 to download, 1 differs on both sides, 1 unchanged (dry run: nothing was changed)
        OUT

        assert_equal server_before, remote_list(port), "status must not change the server (keys, hashes, modified_at)"
        assert_equal local_before, snapshot(dst), "status must not create, modify or remove anything locally"
        assert_equal local_hashes(src), remote_hashes(port)
        assert_equal "local version!", File.read(File.join(dst, "docs/changed.txt"))

        # Exit code 0 is for a successful comparison, with or without differences.
        stdout, stderr, status = run_client("status", src, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal "status: in sync, 4 file(s) identical on both sides (dry run: nothing was changed)\n", stdout
        assert_equal "", stderr
      end
    end
  end

  def test_status_sends_nothing_but_get_blobs
    with_tmpdir do |dir|
      write(dir, "local-only.txt", "mine")
      write(dir, "changed.txt", "v2")
      write(dir, "same.txt", "same")
      listing = [
        { "key" => "changed.txt", "size" => 2, "sha256" => Digest::SHA256.hexdigest("v1"), "modified_at" => "2026-01-01T00:00:00.000Z" },
        { "key" => "remote-only.txt", "size" => 1, "sha256" => Digest::SHA256.hexdigest("r"), "modified_at" => "2026-01-01T00:00:00.000Z" },
        { "key" => "same.txt", "size" => 4, "sha256" => Digest::SHA256.hexdigest("same"), "modified_at" => "2026-01-01T00:00:00.000Z" }
      ]
      RecordingHttpServer.open(listing) do |server|
        before = snapshot(dir)
        stdout, stderr, status = run_client("status", dir, "--server", "http://127.0.0.1:#{server.port}")
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal "", stderr
        assert_equal <<~OUT, stdout
          upload    local-only.txt  (missing on server, 4 bytes)
          download  remote-only.txt  (missing locally, 1 bytes)
          differs   changed.txt  (local 2 bytes, server 2 bytes; push would upload, pull would download)
          status: 1 to upload, 1 to download, 1 differs on both sides, 1 unchanged (dry run: nothing was changed)
        OUT
        assert_equal [["GET", "/blobs"]], server.requests, "status may only list; no PUT, DELETE or blob GET"
        assert_equal before, snapshot(dir)
      end
    end
  end

  def test_status_from_an_unreachable_server_fails_fast_with_a_clear_message
    with_tmpdir do |dir|
      write(dir, "f.txt", "f")
      port = free_port
      stdout, stderr, status = run_client("status", dir, "--server", "http://127.0.0.1:#{port}")
      assert_equal 1, status.exitstatus
      assert_equal "", stdout
      assert_match(/\Asyncbox: cannot reach server at http:\/\/127\.0\.0\.1:#{port}: /, stderr)
      assert_match(/refused/i, stderr)
    end
  end

  def test_status_into_a_missing_directory_fails
    with_tmpdir do |dir|
      _, stderr, status = run_client("status", File.join(dir, "nope"), "--server", "http://127.0.0.1:1")
      assert_equal 1, status.exitstatus
      assert_match(/syncbox: not a directory: .*nope/, stderr)
    end
  end

  def test_sync_copies_both_ways_then_resolves_conflicts_by_the_spec_rule
    with_tmpdir do |dir|
      laptop = File.join(dir, "laptop")
      desktop = File.join(dir, "desktop")
      write(laptop, "docs/readme.txt", "hello")
      write(laptop, "sp ace/ü.txt", "")
      write(laptop, ".hidden", "h")
      big = Random.new(13).bytes(1_500_000)
      write(laptop, "big.bin", big)
      write(desktop, "notes/todo.txt", "buy milk")
      write(desktop, "docs/readme.txt", "hello")

      with_running_server(File.join(dir, "store")) do |port|
        url = "http://127.0.0.1:#{port}"

        # First run from the laptop: the server is empty, everything goes up.
        stdout, stderr, status = run_client("sync", laptop, "--server", url)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal "", stderr
        assert_equal <<~OUT, stdout
          uploaded .hidden (new, 1 bytes)
          uploaded big.bin (new, 1500000 bytes)
          uploaded docs/readme.txt (new, 5 bytes)
          uploaded sp ace/ü.txt (new, 0 bytes)
          sync done: 4 uploaded, 0 downloaded, 0 unchanged, 0 conflict(s) resolved
        OUT
        assert_equal local_hashes(laptop).except(".syncbox/state.json"), remote_hashes(port)
        assert File.file?(File.join(laptop, ".syncbox/state.json")), "the common state is kept in <dir>/.syncbox"
        refute_includes remote_hashes(port).keys, ".syncbox/state.json", "the state is never uploaded"

        # First run on the desktop: local-only file goes up, server-only
        # files come down, the identical one is left alone.
        stdout, stderr, status = run_client("sync", desktop, "--server", url)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal "", stderr
        assert_equal <<~OUT, stdout
          downloaded .hidden (new, 1 bytes)
          downloaded big.bin (new, 1500000 bytes)
          uploaded notes/todo.txt (new, 8 bytes)
          downloaded sp ace/ü.txt (new, 0 bytes)
          sync done: 1 uploaded, 3 downloaded, 1 unchanged, 0 conflict(s) resolved
        OUT
        assert_equal local_hashes(desktop).except(".syncbox/state.json"), remote_hashes(port), "desktop and server agree byte for byte"
        assert_equal big, File.binread(File.join(desktop, "big.bin"))

        # Nothing changed: nothing moves, local mtimes stay.
        before = mtimes(desktop)
        stdout, stderr, status = run_client("sync", desktop, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal "sync done: 0 uploaded, 0 downloaded, 5 unchanged, 0 conflict(s) resolved\n", stdout
        assert_equal before, mtimes(desktop)

        # Changed only locally: the server gets the local version. Changed
        # only on the server: the desktop gets the server's version. The
        # local edit is dated far in the past and the server-side edit is
        # the most recent event of all: with a known common state the
        # timestamps play no role, these are not conflicts.
        write(desktop, "notes/todo.txt", "buy milk and bread")
        File.utime(Time.utc(2000, 1, 1), Time.utc(2000, 1, 1), File.join(desktop, "notes/todo.txt"))
        put_blob(port, "docs/readme.txt", "hello world")
        stdout, stderr, status = run_client("sync", desktop, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal <<~OUT, stdout
          downloaded docs/readme.txt (changed on server, 11 bytes)
          uploaded notes/todo.txt (changed locally, 18 bytes)
          sync done: 1 uploaded, 1 downloaded, 3 unchanged, 0 conflict(s) resolved
        OUT
        assert_equal "buy milk and bread", Net::HTTP.get(URI("#{url}/blobs/notes/todo.txt"))
        assert_equal "hello world", File.read(File.join(desktop, "docs/readme.txt"))

        # Conflicts: both sides edit the same file since the last sync.
        #   big.bin        local edit dated 2000, server edit now: server wins
        #   sp ace/ü.txt   local edit dated 2100, server edit now: local wins
        write(desktop, "big.bin", "local big")
        File.utime(Time.utc(2000, 1, 1), Time.utc(2000, 1, 1), File.join(desktop, "big.bin"))
        put_blob(port, "big.bin", "server big")
        write(desktop, "sp ace/ü.txt", "local ü")
        File.utime(Time.utc(2100, 1, 1), Time.utc(2100, 1, 1), File.join(desktop, "sp ace/ü.txt"))
        put_blob(port, "sp ace/ü.txt", "server ü")
        stdout, stderr, status = run_client("sync", desktop, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal <<~OUT, stdout
          downloaded big.bin (conflict, server is newer, 10 bytes)
          uploaded sp ace/ü.txt (conflict, local is newer, 8 bytes)
          sync done: 1 uploaded, 1 downloaded, 3 unchanged, 2 conflict(s) resolved
        OUT
        assert_equal "server big", File.read(File.join(desktop, "big.bin"))
        assert_equal "server big", Net::HTTP.get(URI("#{url}/blobs/big.bin"))
        assert_equal "local ü", File.read(File.join(desktop, "sp ace/ü.txt"))
        assert_equal "local ü", Net::HTTP.get(URI("#{url}/blobs/sp%20ace/%C3%BC.txt")).force_encoding(Encoding::UTF_8)

        # Conflict with equal timestamps: the local mtime is set to exactly
        # the modified_at the server reports, so the local version wins.
        put_blob(port, ".hidden", "server hidden")
        modified_at = remote_list(port).find { |m| m["key"] == ".hidden" }.fetch("modified_at")
        instant = Time.iso8601(modified_at)
        write(desktop, ".hidden", "local hidden")
        File.utime(instant, instant, File.join(desktop, ".hidden"))
        stdout, stderr, status = run_client("sync", desktop, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal <<~OUT, stdout
          uploaded .hidden (conflict, same mtime, local wins, 12 bytes)
          sync done: 1 uploaded, 0 downloaded, 4 unchanged, 1 conflict(s) resolved
        OUT
        assert_equal "local hidden", Net::HTTP.get(URI("#{url}/blobs/.hidden"))
        assert_equal "local hidden", File.read(File.join(desktop, ".hidden"))

        # Deletions are not propagated: a file removed on one side comes
        # back from the other.
        File.delete(File.join(desktop, "notes/todo.txt"))
        Net::HTTP.start("127.0.0.1", port) { |http| http.delete("/blobs/docs/readme.txt") }
        stdout, stderr, status = run_client("sync", desktop, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal <<~OUT, stdout
          uploaded docs/readme.txt (missing on server, 11 bytes)
          downloaded notes/todo.txt (missing locally, 18 bytes)
          sync done: 1 uploaded, 1 downloaded, 3 unchanged, 0 conflict(s) resolved
        OUT
        assert_equal "buy milk and bread", File.read(File.join(desktop, "notes/todo.txt"))
        assert_equal "hello world", Net::HTTP.get(URI("#{url}/blobs/docs/readme.txt"))
        assert_equal local_hashes(desktop).except(".syncbox/state.json"), remote_hashes(port)
        assert_equal [], Dir.glob("**/.syncbox-tmp-*", File::FNM_DOTMATCH, base: desktop), "no staging files left behind"

        # The laptop, last synced before all of this, catches up in one run:
        # every file it has is still the common version, so only downloads.
        stdout, stderr, status = run_client("sync", laptop, "--server", url)
        assert_equal 0, status.exitstatus, stderr
        assert_equal <<~OUT, stdout
          downloaded .hidden (changed on server, 12 bytes)
          downloaded big.bin (changed on server, 10 bytes)
          downloaded docs/readme.txt (changed on server, 11 bytes)
          downloaded notes/todo.txt (new, 18 bytes)
          downloaded sp ace/ü.txt (changed on server, 8 bytes)
          sync done: 0 uploaded, 5 downloaded, 0 unchanged, 0 conflict(s) resolved
        OUT
        assert_equal local_hashes(laptop).except(".syncbox/state.json"), local_hashes(desktop).except(".syncbox/state.json")
      end
    end
  end

  def test_sync_with_the_server_url_from_the_environment_and_a_relative_dir
    with_tmpdir do |dir|
      write(File.join(dir, "src"), "f.txt", "f")
      with_running_server(File.join(dir, "store")) do |port|
        stdout, stderr, status = run_client("sync", "src", env: { "SYNCBOX_SERVER" => "http://localhost:#{port}/" }, chdir: dir)
        assert_equal 0, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
        assert_equal ["f.txt"], remote_hashes(port).keys
        state = JSON.parse(File.read(File.join(dir, "src/.syncbox/state.json")))
        assert_equal ["http://localhost:#{port}"], state["servers"].keys, "the state is keyed by the normalised server URL"
      end
    end
  end

  def test_sync_from_an_unreachable_server_fails_fast_with_a_clear_message
    with_tmpdir do |dir|
      write(dir, "f.txt", "f")
      port = free_port
      stdout, stderr, status = run_client("sync", dir, "--server", "http://127.0.0.1:#{port}")
      assert_equal 1, status.exitstatus
      assert_equal "", stdout
      assert_match(/\Asyncbox: cannot reach server at http:\/\/127\.0\.0\.1:#{port}: /, stderr)
      assert_match(/refused/i, stderr)
      assert_equal ["f.txt"], Dir.children(dir), "nothing is written, not even an empty state"
    end
  end

  def test_sync_into_a_missing_directory_fails
    with_tmpdir do |dir|
      _, stderr, status = run_client("sync", File.join(dir, "nope"), "--server", "http://127.0.0.1:1")
      assert_equal 1, status.exitstatus
      assert_match(/syncbox: not a directory: .*nope/, stderr)
    end
  end

  # A minimal HTTP/1.1 server that records every request it receives, answers
  # GET /blobs with a fixed listing and everything else with 500 — proof of
  # which requests a command sends, independent of the real server's state.
  class RecordingHttpServer
    attr_reader :port

    def self.open(listing)
      server = new(listing)
      yield server
    ensure
      server&.close
    end

    def initialize(listing)
      @body = JSON.generate(listing)
      @socket = TCPServer.new("127.0.0.1", 0)
      @port = @socket.addr[1]
      @requests = []
      @mutex = Mutex.new
      @acceptor = Thread.new { accept_loop }
    end

    def requests
      @mutex.synchronize { @requests.dup }
    end

    def close
      @socket.close
      @acceptor.join(5)
    end

    private

    def accept_loop
      loop do
        conn = @socket.accept
        Thread.new { serve(conn) }
      end
    rescue IOError, SystemCallError
      nil # socket closed
    end

    def serve(conn)
      while (request_line = conn.gets)
        method, path, = request_line.split(" ")
        headers = {}
        while (line = conn.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.to_s.strip
        end
        conn.read(headers["content-length"].to_i) if headers["content-length"]
        @mutex.synchronize { @requests << [method, path] }
        if method == "GET" && path == "/blobs"
          respond(conn, "200 OK", "application/json", @body)
        else
          respond(conn, "500 Internal Server Error", "text/plain", "unexpected #{method} #{path}")
        end
      end
    rescue IOError, SystemCallError
      nil
    ensure
      conn.close
    end

    def respond(conn, status, type, body)
      conn.write "HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
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

  def put_blob(port, key, content)
    Net::HTTP.start("127.0.0.1", port) do |http|
      response = http.put("/blobs/#{Syncbox::Client::Api.encode_key(key)}", content, "content-type" => "application/octet-stream")
      assert_equal "201", response.code, response.body
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

  # Every entry under +dir+ with its type, content hash and mtime — enough to
  # notice any creation, modification or removal.
  def snapshot(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.map do |rel|
      path = File.join(dir, rel)
      stat = File.lstat(path)
      [rel, stat.ftype, stat.file? ? Digest::SHA256.file(path).hexdigest : nil, stat.mtime]
    end
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
