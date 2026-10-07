# frozen_string_literal: true

require "test_helper"
require "open3"
require "stringio"

# syncbox push против настоящего сервера: что загружается, что пропускается,
# коды возврата и сообщения — через Syncbox::Client::CLI в процессе и через
# bin/syncbox отдельным процессом.
class ClientPushTest < Minitest::Test
  include Syncbox::TestSupport

  def setup
    @tmp = Dir.mktmpdir("syncbox-push")
    @dir = File.join(@tmp, "local")
    FileUtils.mkdir_p(@dir)
    @server = Syncbox::TestSupport::ServerProcess.new(File.join(@tmp, "data"))
  end

  def teardown
    @server&.stop
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

  def push(dir = @dir, server = @server.url)
    run_cli(["push", dir, "--server", server])
  end

  def server_mtimes
    @server.keys.to_h { |key| [key, File.mtime(File.join(@server.data_dir, key))] }
  end

  def test_first_push_uploads_every_file_and_reports_it
    files = {
      "a.txt" => "alpha",
      "docs/readme.txt" => "# readme",
      "docs/sub/deep/x.bin" => (0..255).map(&:chr).join.b * 300,
      ".hidden/.dotfile" => "dot",
      "empty" => "",
      "каталог/файл с пробелом.txt" => "unicode",
      "odd %?#+&.txt" => "odd"
    }
    files.each { |rel, content| write(rel, content) }

    status, out, err = push
    assert_equal 0, status, err
    assert_equal "", err

    expected_lines = files.keys.sort.map { |key| "uploaded #{key} (#{files[key].bytesize} bytes)" }
    expected_lines << "push complete: #{files.size} uploaded, 0 unchanged, #{files.size} files total"
    assert_equal expected_lines, out.lines(chomp: true)

    assert_equal files.keys.sort, @server.keys
    files.each do |key, content|
      assert_equal content, @server.blob(key), key
    end
    @server.list.each do |meta|
      assert_equal Digest::SHA256.hexdigest(files.fetch(meta["key"])), meta["sha256"]
    end
  end

  def test_second_push_uploads_nothing
    write("a.txt", "alpha")
    write("docs/readme.txt", "readme")
    assert_equal 0, push.first
    before = server_mtimes

    status, out, err = push
    assert_equal 0, status, err
    assert_equal ["unchanged a.txt", "unchanged docs/readme.txt", "push complete: 0 uploaded, 2 unchanged, 2 files total"],
                 out.lines(chomp: true)
    assert_equal before, server_mtimes, "identical files must not be re-uploaded"
  end

  def test_only_changed_and_new_files_are_uploaded_and_server_extras_are_kept
    write("same.txt", "same")
    write("changed.txt", "v1")
    write("gone.txt", "will be removed locally")
    assert_equal 0, push.first
    @server.put("server-only.txt", "server side")
    before = server_mtimes

    write("changed.txt", "v2")
    write("new/file.txt", "new")
    File.delete(File.join(@dir, "gone.txt"))

    status, out, err = push
    assert_equal 0, status, err
    assert_equal ["uploaded changed.txt (2 bytes)", "uploaded new/file.txt (3 bytes)", "unchanged same.txt",
                  "push complete: 2 uploaded, 1 unchanged, 3 files total"], out.lines(chomp: true)

    assert_equal "v2", @server.blob("changed.txt")
    assert_equal "new", @server.blob("new/file.txt")
    assert_equal "same", @server.blob("same.txt")
    assert_equal "will be removed locally", @server.blob("gone.txt"), "push never deletes on the server"
    assert_equal "server side", @server.blob("server-only.txt")
    assert_equal before["same.txt"], server_mtimes["same.txt"]
    assert_equal before["gone.txt"], server_mtimes["gone.txt"]
    assert_equal before["server-only.txt"], server_mtimes["server-only.txt"]
  end

  def test_same_size_different_content_is_detected_by_sha256
    @server.put("x.txt", "AAAA")
    write("x.txt", "AAAB")
    status, out, = push
    assert_equal 0, status
    assert_includes out, "uploaded x.txt (4 bytes)"
    assert_equal "AAAB", @server.blob("x.txt")
  end

  def test_touching_a_file_without_changing_content_does_not_upload
    write("x.txt", "same")
    assert_equal 0, push.first
    sleep 0.01
    FileUtils.touch(File.join(@dir, "x.txt"))
    status, out, = push
    assert_equal 0, status
    assert_equal ["unchanged x.txt", "push complete: 0 uploaded, 1 unchanged, 1 files total"], out.lines(chomp: true)
  end

  def test_large_file_is_streamed_intact
    content = Random.new(7).bytes(3 * 1024 * 1024 + 123)
    write("big/blob.bin", content)
    status, out, err = push
    assert_equal 0, status, err
    assert_includes out, "uploaded big/blob.bin (#{content.bytesize} bytes)"
    assert_equal content, @server.blob("big/blob.bin")
  end

  def test_empty_directory_pushes_nothing_successfully
    status, out, err = push
    assert_equal 0, status
    assert_equal "", err
    assert_equal ["push complete: 0 uploaded, 0 unchanged, 0 files total"], out.lines(chomp: true)
    assert_equal [], @server.keys
  end

  def test_skipped_entries_are_reported_on_stderr_and_do_not_fail_the_push
    write("ok.txt", "ok")
    File.mkfifo(File.join(@dir, "pipe"))
    File.symlink(File.join(@dir, "missing"), File.join(@dir, "broken"))
    status, out, err = push
    assert_equal 0, status
    assert_match(/^syncbox: skipping broken: broken symlink/, err)
    assert_match(/^syncbox: skipping pipe: not a regular file \(fifo\)/, err)
    assert_includes out, "uploaded ok.txt (2 bytes)"
    assert_equal ["ok.txt"], @server.keys
  end

  def test_server_rejecting_a_key_is_a_per_file_failure_and_the_other_files_are_still_pushed
    write("a.txt", "a")
    write(".syncbox-tmp/reserved", "x")
    status, out, err = push
    assert_equal 1, status
    assert_equal ["failed .syncbox-tmp/reserved", "uploaded a.txt (1 bytes)",
                  "push incomplete: 1 uploaded, 0 unchanged, 1 failed, 2 files total"], out.lines(chomp: true)
    assert_match(%r{^syncbox: failed \.syncbox-tmp/reserved: PUT /blobs/\.syncbox-tmp/reserved: server responded 400: key uses reserved name}, err)
    assert_match(%r{^syncbox: push failed for 1 of 2 files:\n  \.syncbox-tmp/reserved: PUT /blobs/\.syncbox-tmp/reserved: server responded 400}, err)
    assert_equal ["a.txt"], @server.keys, "the push continues past the failed file"
  end

  def test_unreachable_server_fails_with_a_message_and_exit_1
    write("a.txt", "a")
    port = free_port
    status, out, err = push(@dir, "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: cannot connect to server http://127\.0\.0\.1:#{port}: }, err)
  end

  def test_missing_directory_fails_with_exit_1
    status, out, err = push(File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: directory not found: .*nope$}, err)
  end

  def test_unreadable_file_is_a_per_file_failure_with_exit_1
    skip "root ignores file permissions" if Process.uid.zero?
    write("a.txt", "a")
    path = write("secret.txt", "x")
    write("z.txt", "z")
    File.chmod(0o000, path)
    status, out, err = push
    assert_equal 1, status
    assert_equal ["uploaded a.txt (1 bytes)", "failed secret.txt", "uploaded z.txt (1 bytes)",
                  "push incomplete: 2 uploaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    assert_match(/^syncbox: failed secret\.txt: Permission denied .*secret\.txt/, err)
    assert_match(/^syncbox: push failed for 1 of 3 files:\n  secret\.txt: Permission denied/, err)
    assert_equal %w[a.txt z.txt], @server.keys
  ensure
    File.chmod(0o644, path) if path
  end

  def test_usage_errors_exit_2_with_usage_text
    status, out, err = run_cli(["push", @dir])
    assert_equal 2, status
    assert_equal "", out
    assert_match(/^syncbox: --server is required/, err)
    assert_match(/^Usage: syncbox/, err)

    status, _out, err = run_cli([])
    assert_equal 2, status
    assert_match(/^syncbox: command is required/, err)

    status, _out, err = run_cli(["frobnicate", @dir, "--server", @server.url])
    assert_equal 2, status
    assert_match(/^syncbox: unknown command "frobnicate"/, err)
  end

  def test_help_exits_0
    status, out, err = run_cli(["--help"])
    assert_equal 0, status
    assert_equal "", err
    assert_match(/^Usage: syncbox/, out)
  end

  # --- bin/syncbox как отдельный процесс -----------------------------------

  def run_bin(*args, env: {})
    base_env = { "SYNCBOX_SERVER" => nil }
    Open3.capture3(base_env.merge(env), CLIENT_BIN, *args)
  end

  def test_bin_push_with_server_from_environment
    write("a.txt", "alpha")
    out, err, status = run_bin("push", @dir, env: { "SYNCBOX_SERVER" => @server.url })
    assert_equal 0, status.exitstatus, err
    assert_equal ["uploaded a.txt (5 bytes)", "push complete: 1 uploaded, 0 unchanged, 1 files total"], out.lines(chomp: true)
    assert_equal "alpha", @server.blob("a.txt")
  end

  def test_bin_exit_codes
    _out, err, status = run_bin("push", @dir)
    assert_equal 2, status.exitstatus
    assert_match(/--server is required/, err)

    out, _err, status = run_bin("--help")
    assert_equal 0, status.exitstatus
    assert_match(/Usage: syncbox/, out)

    _out, err, status = run_bin("push", @dir, "--server", "http://127.0.0.1:#{free_port}")
    assert_equal 1, status.exitstatus
    assert_match(/cannot connect to server/, err)
  end
end
