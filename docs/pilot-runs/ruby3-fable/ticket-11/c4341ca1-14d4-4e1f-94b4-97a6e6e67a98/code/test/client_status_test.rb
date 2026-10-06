# frozen_string_literal: true

require "test_helper"
require "open3"
require "stringio"

# syncbox status против настоящего сервера: направление для локально-нового,
# серверно-нового и разошедшегося по содержимому файла, вывод «в синхроне»,
# код возврата 0 при любых расхождениях — и главное: status ничего не
# меняет ни на сервере, ни в локальной ФС. Что на сервер уходит только
# GET /blobs — против поддельного сервера (TestSupport::FakeServer).
class ClientStatusTest < Minitest::Test
  include Syncbox::TestSupport

  FakeServer = Syncbox::TestSupport::FakeServer

  def setup
    @tmp = Dir.mktmpdir("syncbox-status")
    @dir = File.join(@tmp, "local")
    FileUtils.mkdir_p(@dir)
    @server = Syncbox::TestSupport::ServerProcess.new(File.join(@tmp, "data"))
    @fake = nil
  end

  def teardown
    @server&.stop
    @fake&.stop
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def write(rel, content = rel)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  # Запуск CLI в процессе: [status, stdout, stderr].
  def run_cli(argv, env = {})
    out = StringIO.new
    err = StringIO.new
    status = Syncbox::Client::CLI.run(argv, env: env, out: out, err: err)
    [status, out.string, err.string]
  end

  def run_status(dir = @dir, server = @server.url)
    run_cli(["status", dir, "--server", server])
  end

  # Полный снимок локального каталога: относительный путь → [тип, mtime, содержимое].
  def local_snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).reject { |rel| rel == "." }.sort.to_h do |rel|
      path = File.join(@dir, rel)
      stat = File.lstat(path)
      [rel, [stat.ftype, stat.mtime, stat.file? ? File.binread(path) : nil]]
    end
  end

  # Полный снимок сервера: листинг плюс mtime файлов в каталоге данных.
  def server_snapshot
    [@server.list, Dir.glob("**/*", File::FNM_DOTMATCH, base: @server.data_dir).sort.map { |rel| [rel, File.mtime(File.join(@server.data_dir, rel))] }]
  end

  def sha(content)
    Digest::SHA256.hexdigest(content)
  end

  def test_local_only_file_would_be_uploaded
    write("new-local.txt", "hello")
    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal "", err
    assert_equal ["upload    new-local.txt (5 bytes; only local, not on server)",
                  "status: 1 to upload (1 only local), 0 to download (0 only on server), 0 differing on both sides, " \
                  "0 unchanged, 1 files total (dry run, nothing changed)"], out.lines(chomp: true)
  end

  def test_server_only_blob_would_be_downloaded
    @server.put("new/remote.txt", "from server")
    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal ["download  new/remote.txt (11 bytes; only on server, not local)",
                  "status: 0 to upload (0 only local), 1 to download (1 only on server), 0 differing on both sides, " \
                  "0 unchanged, 1 files total (dry run, nothing changed)"], out.lines(chomp: true)
  end

  def test_file_differing_by_content_is_reported_in_both_directions
    write("changed.txt", "local version")
    @server.put("changed.txt", "server version!")
    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal ["differs   changed.txt (local 13 bytes, server 15 bytes; push would upload, pull would download)",
                  "status: 1 to upload (0 only local), 1 to download (0 only on server), 1 differing on both sides, " \
                  "0 unchanged, 1 files total (dry run, nothing changed)"], out.lines(chomp: true)
  end

  def test_same_size_different_content_is_detected_by_sha256
    write("x.txt", "AAAA")
    @server.put("x.txt", "AAAB")
    _status, out, = run_status
    assert_includes out, "differs   x.txt (local 4 bytes, server 4 bytes; push would upload, pull would download)"
  end

  def test_identical_files_are_unchanged_even_with_a_different_mtime
    write("same.txt", "same")
    @server.put("same.txt", "same")
    sleep 0.01
    FileUtils.touch(File.join(@dir, "same.txt"))
    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal ["unchanged same.txt",
                  "status: in sync, 1 unchanged, nothing to upload or download (dry run, nothing changed)"], out.lines(chomp: true)
  end

  def test_mixed_tree_is_reported_per_key_in_key_order
    write("a/local-only.txt", "L")
    write("b/same.bin", "\x00\xff".b)
    write("c/differs.txt", "v-local")
    write("каталог/файл.txt", "unicode")
    @server.put("b/same.bin", "\x00\xff".b)
    @server.put("c/differs.txt", "v-server")
    @server.put("d/server-only.txt", "S")
    @server.put("каталог/файл.txt", "unicode")

    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal "", err
    assert_equal [
      "upload    a/local-only.txt (1 bytes; only local, not on server)",
      "unchanged b/same.bin",
      "differs   c/differs.txt (local 7 bytes, server 8 bytes; push would upload, pull would download)",
      "download  d/server-only.txt (1 bytes; only on server, not local)",
      "unchanged каталог/файл.txt",
      "status: 2 to upload (1 only local), 2 to download (1 only on server), 1 differing on both sides, " \
      "2 unchanged, 5 files total (dry run, nothing changed)"
    ], out.lines(chomp: true)
  end

  def test_empty_dir_and_empty_server_are_in_sync
    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal ["status: in sync, 0 unchanged, nothing to upload or download (dry run, nothing changed)"], out.lines(chomp: true)
  end

  def test_status_changes_nothing_on_either_side
    write("local-only.txt", "L")
    write("same.txt", "same")
    write("differs.txt", "v-local")
    @server.put("same.txt", "same")
    @server.put("differs.txt", "v-server")
    @server.put("server-only.txt", "S")
    local_before = local_snapshot
    server_before = server_snapshot

    status, out, err = run_status
    assert_equal 0, status, err
    refute_includes out, "status: in sync"

    assert_equal local_before, local_snapshot, "status must not create, change or delete local files"
    assert_equal server_before, server_snapshot, "status must not change the server"
    assert_equal %w[differs.txt same.txt server-only.txt], @server.keys
    assert_equal "v-server", @server.blob("differs.txt")
    assert_nil @server.blob("local-only.txt")
    assert_equal "v-local", File.binread(File.join(@dir, "differs.txt"))
    refute File.exist?(File.join(@dir, "server-only.txt"))
    assert_empty Dir.glob("**/.syncbox-*", File::FNM_DOTMATCH, base: @dir), "no temp files"
  end

  def test_status_works_on_a_read_only_directory
    skip "root ignores directory permissions" if Process.uid.zero?
    write("sub/local-only.txt", "L")
    write("sub/differs.txt", "v-local")
    @server.put("sub/differs.txt", "v-server")
    @server.put("server-only.txt", "S")
    [File.join(@dir, "sub"), @dir].each { |d| File.chmod(0o555, d) }

    status, out, err = run_status
    assert_equal 0, status, err
    assert_equal ["download  server-only.txt (1 bytes; only on server, not local)",
                  "differs   sub/differs.txt (local 7 bytes, server 8 bytes; push would upload, pull would download)",
                  "upload    sub/local-only.txt (1 bytes; only local, not on server)"], out.lines(chomp: true)[0, 3]
  ensure
    [File.join(@dir, "sub"), @dir].each { |d| File.chmod(0o755, d) if File.directory?(d) }
  end

  def test_only_the_listing_is_requested_from_the_server
    write("local-only.txt", "L")
    write("same.txt", "same")
    write("differs.txt", "v-local")
    @fake = FakeServer.new("GET /blobs" => [200, FakeServer.listing(["same.txt", "same"], ["differs.txt", "v-server"], ["server-only.txt", "S"])])

    status, out, err = run_status(@dir, @fake.url)
    assert_equal 0, status, err
    assert_equal ["GET /blobs"], @fake.requests, "status must send nothing but a single GET /blobs"
    assert_equal ["differs   differs.txt (local 7 bytes, server 8 bytes; push would upload, pull would download)",
                  "upload    local-only.txt (1 bytes; only local, not on server)",
                  "unchanged same.txt",
                  "download  server-only.txt (1 bytes; only on server, not local)"], out.lines(chomp: true)[0, 4]
  end

  def test_malformed_listing_entry_is_an_error
    @fake = FakeServer.new("GET /blobs" => [200, JSON.generate([{ "key" => "x", "size" => 1 }])])
    status, _out, err = run_status(@dir, @fake.url)
    assert_equal 1, status
    assert_match(%r{^syncbox: GET /blobs: malformed entry in server listing: }, err)
  end

  def test_listing_without_size_is_still_compared
    write("x.txt", "x")
    @fake = FakeServer.new("GET /blobs" => [200, JSON.generate([{ "key" => "x.txt", "sha256" => sha("y") }])])
    status, out, = run_status(@dir, @fake.url)
    assert_equal 0, status
    assert_includes out, "differs   x.txt (local 1 bytes, server size unknown; push would upload, pull would download)"
  end

  def test_symlink_to_a_file_is_compared_by_target_content
    target = File.join(@tmp, "outside-target.txt")
    File.binwrite(target, "same")
    File.symlink(target, File.join(@dir, "link.txt"))
    @server.put("link.txt", "same")
    _status, out, = run_status
    assert_includes out.lines(chomp: true), "unchanged link.txt"
  end

  def test_skipped_entries_are_reported_on_stderr_and_do_not_fail_the_status
    write("ok.txt", "ok")
    File.mkfifo(File.join(@dir, "pipe"))
    status, out, err = run_status
    assert_equal 0, status
    assert_match(/^syncbox: skipping pipe: not a regular file \(fifo\)/, err)
    assert_includes out, "upload    ok.txt (2 bytes; only local, not on server)"
  end

  def test_unreachable_server_fails_with_a_message_and_exit_1
    write("a.txt", "a")
    port = free_port
    status, out, err = run_status(@dir, "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: cannot connect to server http://127\.0\.0\.1:#{port}: }, err)
  end

  def test_missing_directory_fails_with_exit_1_before_touching_the_network
    @server.stop
    status, out, err = run_status(File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: directory not found: .*nope$}, err)
  end

  def test_unreadable_local_file_is_reported_as_not_compared_with_exit_1
    skip "root ignores file permissions" if Process.uid.zero?
    write("a.txt", "a")
    path = write("secret.txt", "x")
    @server.put("b.txt", "b")
    File.chmod(0o000, path)
    status, out, err = run_status
    assert_equal 1, status
    assert_equal ["upload    a.txt (1 bytes; only local, not on server)",
                  "download  b.txt (1 bytes; only on server, not local)",
                  "failed    secret.txt (not compared, see stderr)",
                  "status: 1 failed (not compared), 1 to upload (1 only local), 1 to download (1 only on server), " \
                  "0 differing on both sides, 0 unchanged, 3 files total (dry run, nothing changed)"], out.lines(chomp: true)
    assert_match(/^syncbox: failed secret\.txt: Permission denied .*secret\.txt/, err)
    assert_match(/^syncbox: status failed for 1 of 3 files:\n  secret\.txt: Permission denied/, err)
  ensure
    File.chmod(0o644, path) if path
  end

  # --- bin/syncbox как отдельный процесс -----------------------------------

  def run_bin(*args, env: {})
    base_env = { "SYNCBOX_SERVER" => nil }
    Open3.capture3(base_env.merge(env), CLIENT_BIN, *args)
  end

  def test_bin_status_with_server_from_environment_exits_0_despite_differences
    write("a.txt", "alpha")
    @server.put("b.txt", "beta")
    out, err, status = run_bin("status", @dir, env: { "SYNCBOX_SERVER" => @server.url })
    assert_equal 0, status.exitstatus, err
    assert_equal "", err
    assert_equal ["upload    a.txt (5 bytes; only local, not on server)",
                  "download  b.txt (4 bytes; only on server, not local)",
                  "status: 1 to upload (1 only local), 1 to download (1 only on server), 0 differing on both sides, " \
                  "0 unchanged, 2 files total (dry run, nothing changed)"], out.lines(chomp: true)
    assert_equal ["b.txt"], @server.keys
    assert_equal ["a.txt"], Dir.children(@dir)
  end

  def test_bin_status_exit_codes
    _out, err, status = run_bin("status", @dir)
    assert_equal 2, status.exitstatus
    assert_match(/--server is required/, err)

    _out, err, status = run_bin("status", @dir, "--server", "http://127.0.0.1:#{free_port}")
    assert_equal 1, status.exitstatus
    assert_match(/cannot connect to server/, err)
  end
end
