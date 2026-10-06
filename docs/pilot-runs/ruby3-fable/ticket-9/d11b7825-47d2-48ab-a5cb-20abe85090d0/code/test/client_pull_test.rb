# frozen_string_literal: true

require "test_helper"
require "open3"
require "stringio"

# syncbox pull против настоящего сервера: что скачивается, что пропускается,
# куда пишется, коды возврата и сообщения — через Syncbox::Client::CLI в
# процессе и через bin/syncbox отдельным процессом. Недоверенные ответы
# сервера (traversal в key, расхождение хеша, 404 на листинговый key)
# проверяются против поддельного HTTP-сервера (TestSupport::FakeServer).
class ClientPullTest < Minitest::Test
  include Syncbox::TestSupport

  def setup
    @tmp = Dir.mktmpdir("syncbox-pull")
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

  def local(rel)
    File.binread(File.join(@dir, rel))
  end

  # Запуск CLI в процессе: [status, stdout, stderr].
  def run_cli(argv, env = {})
    out = StringIO.new
    err = StringIO.new
    status = Syncbox::Client::CLI.run(argv, env: env, out: out, err: err)
    [status, out.string, err.string]
  end

  def pull(dir = @dir, server = @server.url)
    run_cli(["pull", dir, "--server", server])
  end

  # Относительные пути всех файлов и symlink'ов под @dir (включая dot-файлы).
  def local_entries
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).reject { |rel| rel == "." || File.directory?(File.join(@dir, rel)) }.sort
  end

  def local_mtimes
    local_entries.to_h { |rel| [rel, File.mtime(File.join(@dir, rel))] }
  end

  def tmp_leftovers
    Dir.glob("**/.syncbox-*.tmp", File::FNM_DOTMATCH, base: @dir)
  end

  def test_first_pull_downloads_every_blob_into_the_right_paths
    blobs = {
      "a.txt" => "alpha",
      "docs/readme.txt" => "# readme",
      "docs/sub/deep/x.bin" => (0..255).map(&:chr).join.b * 300,
      ".hidden/.dotfile" => "dot",
      "empty" => "",
      "каталог/файл с пробелом.txt" => "unicode",
      "odd %?#+&.txt" => "odd"
    }
    blobs.each { |key, content| @server.put(key, content) }

    status, out, err = pull
    assert_equal 0, status, err
    assert_equal "", err

    expected_lines = blobs.keys.sort.map { |key| "downloaded #{key} (#{blobs[key].bytesize} bytes)" }
    expected_lines << "pull complete: #{blobs.size} downloaded, 0 unchanged, #{blobs.size} files total"
    assert_equal expected_lines, out.lines(chomp: true)

    assert_equal blobs.keys.sort, local_entries
    blobs.each do |key, content|
      assert_equal content, local(key), key
      assert_equal Digest::SHA256.hexdigest(content), Digest::SHA256.file(File.join(@dir, key)).hexdigest
    end
    assert_empty tmp_leftovers
  end

  def test_second_pull_downloads_nothing_and_touches_nothing
    @server.put("a.txt", "alpha")
    @server.put("docs/readme.txt", "readme")
    assert_equal 0, pull.first
    before = local_mtimes

    status, out, err = pull
    assert_equal 0, status, err
    assert_equal ["unchanged a.txt", "unchanged docs/readme.txt", "pull complete: 0 downloaded, 2 unchanged, 2 files total"],
                 out.lines(chomp: true)
    assert_equal before, local_mtimes, "identical files must not be re-downloaded"
  end

  def test_only_changed_and_missing_blobs_are_downloaded_and_local_extras_are_kept
    @server.put("same.txt", "same")
    @server.put("changed.txt", "v1")
    @server.put("gone.txt", "will be removed on the server")
    assert_equal 0, pull.first
    write("local-only.txt", "local side")
    before = local_mtimes

    @server.put("changed.txt", "v2")
    @server.put("new/file.txt", "new")
    @server.http.delete("/blobs/gone.txt")

    status, out, err = pull
    assert_equal 0, status, err
    assert_equal ["downloaded changed.txt (2 bytes)", "downloaded new/file.txt (3 bytes)", "unchanged same.txt",
                  "pull complete: 2 downloaded, 1 unchanged, 3 files total"], out.lines(chomp: true)

    assert_equal "v2", local("changed.txt")
    assert_equal "new", local("new/file.txt")
    assert_equal "same", local("same.txt")
    assert_equal "will be removed on the server", local("gone.txt"), "pull never deletes locally"
    assert_equal "local side", local("local-only.txt")
    assert_equal before["same.txt"], local_mtimes["same.txt"]
    assert_equal before["gone.txt"], local_mtimes["gone.txt"]
    assert_equal before["local-only.txt"], local_mtimes["local-only.txt"]
  end

  def test_same_size_different_content_is_detected_by_sha256
    write("x.txt", "AAAA")
    @server.put("x.txt", "AAAB")
    status, out, = pull
    assert_equal 0, status
    assert_includes out, "downloaded x.txt (4 bytes)"
    assert_equal "AAAB", local("x.txt")
  end

  def test_touched_local_file_with_same_content_is_not_downloaded
    @server.put("x.txt", "same")
    assert_equal 0, pull.first
    sleep 0.01
    FileUtils.touch(File.join(@dir, "x.txt"))
    status, out, = pull
    assert_equal 0, status
    assert_equal ["unchanged x.txt", "pull complete: 0 downloaded, 1 unchanged, 1 files total"], out.lines(chomp: true)
  end

  def test_large_blob_is_streamed_intact
    content = Random.new(11).bytes(3 * 1024 * 1024 + 321)
    @server.put("big/blob.bin", content)
    status, out, err = pull
    assert_equal 0, status, err
    assert_includes out, "downloaded big/blob.bin (#{content.bytesize} bytes)"
    assert_equal content, local("big/blob.bin")
  end

  def test_empty_server_pulls_nothing_successfully
    write("keep.txt", "keep")
    status, out, err = pull
    assert_equal 0, status
    assert_equal "", err
    assert_equal ["pull complete: 0 downloaded, 0 unchanged, 0 files total"], out.lines(chomp: true)
    assert_equal ["keep.txt"], local_entries
  end

  def test_pull_then_push_round_trip_transfers_nothing_more
    @server.put("a.txt", "alpha")
    @server.put("d/b.bin", "\x00\xff\x01".b)
    assert_equal 0, pull.first
    status, out, = run_cli(["push", @dir, "--server", @server.url])
    assert_equal 0, status
    assert_equal ["unchanged a.txt", "unchanged d/b.bin", "push complete: 0 uploaded, 2 unchanged, 2 files total"], out.lines(chomp: true)
  end

  def test_replaced_file_keeps_its_permission_bits_and_new_files_get_default_ones
    path = write("script.sh", "old")
    File.chmod(0o750, path)
    @server.put("script.sh", "new")
    @server.put("fresh.txt", "fresh")
    assert_equal 0, pull.first
    assert_equal "new", local("script.sh")
    assert_equal 0o750, File.stat(path).mode & 0o7777
    assert_equal 0o644 & ~File.umask, File.stat(File.join(@dir, "fresh.txt")).mode & 0o7777
  end

  def test_symlink_to_a_file_is_compared_by_target_and_replaced_by_a_regular_file
    target = File.join(@tmp, "outside-target.txt")
    File.binwrite(target, "same")
    File.symlink(target, File.join(@dir, "same-link.txt"))
    File.symlink(target, File.join(@dir, "changed-link.txt"))
    File.symlink(File.join(@dir, "missing"), File.join(@dir, "broken-link.txt"))
    @server.put("same-link.txt", "same")
    @server.put("changed-link.txt", "different")
    @server.put("broken-link.txt", "fixed")

    status, out, err = pull
    assert_equal 0, status, err
    assert_equal ["downloaded broken-link.txt (5 bytes)", "downloaded changed-link.txt (9 bytes)", "unchanged same-link.txt",
                  "pull complete: 2 downloaded, 1 unchanged, 3 files total"], out.lines(chomp: true)
    assert File.symlink?(File.join(@dir, "same-link.txt")), "identical symlink is left alone"
    refute File.symlink?(File.join(@dir, "changed-link.txt")), "differing symlink is replaced by a regular file"
    assert_equal "different", local("changed-link.txt")
    assert_equal "fixed", local("broken-link.txt")
    assert_equal "same", File.binread(target), "the symlink target outside <dir> is never written"
  end

  def test_directory_in_the_way_fails_with_exit_1
    FileUtils.mkdir_p(File.join(@dir, "docs"))
    @server.put("docs", "I am a file on the server")
    status, _out, err = pull
    assert_equal 1, status
    assert_match(%r{^syncbox: cannot write docs: a directory is in the way at .*/docs$}, err)
    assert File.directory?(File.join(@dir, "docs"))
  end

  def test_file_in_the_way_of_a_parent_directory_fails_with_exit_1
    write("docs", "I am a file locally")
    @server.put("docs/readme.txt", "readme")
    status, _out, err = pull
    assert_equal 1, status
    assert_match(%r{^syncbox: cannot write docs/readme\.txt: a parent of .*/docs/readme\.txt is not a directory$}, err)
    assert_equal "I am a file locally", local("docs")
  end

  def test_key_resolving_through_a_symlinked_directory_outside_dir_is_refused
    outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(@dir, "link"))
    @server.put("link/escaped.txt", "escaped")
    status, _out, err = pull
    assert_equal 1, status
    assert_match(%r{^syncbox: refusing to pull "link/escaped\.txt": key resolves outside .* \(through a symlink\)$}, err)
    assert_empty Dir.children(outside)
  end

  def test_symlink_to_a_directory_at_the_target_is_not_replaced_or_written_through
    outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(@dir, "link"))
    @server.put("link", "a file on the server")
    status, _out, err = pull
    assert_equal 1, status
    assert_match(%r{^syncbox: cannot write link: a directory is in the way at .*/link$}, err)
    assert File.symlink?(File.join(@dir, "link"))
    assert_empty Dir.children(outside)
  end

  def test_symlinked_dir_itself_is_fine
    real = File.join(@tmp, "real-dir")
    FileUtils.mkdir_p(real)
    link = File.join(@tmp, "dir-link")
    File.symlink(real, link)
    @server.put("sub/x.txt", "x")
    status, _out, err = pull(link)
    assert_equal 0, status, err
    assert_equal "x", File.binread(File.join(real, "sub", "x.txt"))
  end

  def test_unreachable_server_fails_with_a_message_and_exit_1
    port = free_port
    status, out, err = pull(@dir, "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: cannot connect to server http://127\.0\.0\.1:#{port}: }, err)
  end

  def test_missing_directory_fails_with_exit_1_before_touching_the_network
    @server.stop
    status, out, err = pull(File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: directory not found: .*nope$}, err)

    status, _out, err = pull(write("plain-file", "x"))
    assert_equal 1, status
    assert_match(%r{^syncbox: not a directory: .*plain-file$}, err)
  end

  def test_unwritable_directory_fails_with_exit_1_and_leaves_no_temp_files
    skip "root ignores directory permissions" if Process.uid.zero?
    @server.put("a.txt", "a")
    File.chmod(0o500, @dir)
    status, _out, err = pull
    assert_equal 1, status
    assert_match(%r{^syncbox: cannot write a\.txt: Permission denied}, err)
    assert_empty tmp_leftovers
  ensure
    File.chmod(0o755, @dir)
  end

  def test_unreadable_local_file_fails_with_exit_1
    skip "root ignores file permissions" if Process.uid.zero?
    path = write("secret.txt", "x")
    File.chmod(0o000, path)
    @server.put("secret.txt", "y")
    status, _out, err = pull
    assert_equal 1, status
    assert_match(/^syncbox: Permission denied .*secret\.txt/, err)
    File.chmod(0o644, path)
    assert_equal "x", File.binread(path), "an unreadable local file is not overwritten"
  ensure
    File.chmod(0o644, path) if path
  end

  # --- недоверенный сервер ------------------------------------------------

  FakeServer = Syncbox::TestSupport::FakeServer

  def fake_listing(*entries)
    FakeServer.listing(*entries)
  end

  def test_traversal_keys_from_the_server_are_refused_and_nothing_is_written
    bad_keys = ["../escape.txt", "/abs.txt", "a/../b", "./x", "a//b", "a/", "", "nul\u0000.txt"]
    bad_keys.each do |key|
      @fake&.stop
      @fake = FakeServer.new("GET /blobs" => [200, fake_listing([key, "evil"])])
      status, out, err = pull(@dir, @fake.url)
      assert_equal 1, status, key.inspect
      assert_equal "", out
      assert_match(/^syncbox: refusing to pull #{Regexp.escape(key.inspect)}: key /, err)
      assert_equal ["GET /blobs"], @fake.requests, "no blob must be fetched for #{key.inspect}"
    end
    assert_empty local_entries
    assert_empty Dir.children(@tmp) - %w[local data]
  end

  def test_hash_mismatch_between_listing_and_body_fails_and_leaves_no_file
    write("ok.txt", "ok")
    @fake = FakeServer.new(
      "GET /blobs" => [200, fake_listing(["ok.txt", "ok"], ["x.txt", "listed body"])],
      "GET /blobs/x.txt" => [200, "actual body"]
    )
    status, out, err = pull(@dir, @fake.url)
    assert_equal 1, status
    assert_equal ["unchanged ok.txt"], out.lines(chomp: true)
    assert_match(%r{^syncbox: GET /blobs/x\.txt: downloaded sha256=#{Digest::SHA256.hexdigest('actual body')} \(11 bytes\), listing says sha256=#{Digest::SHA256.hexdigest('listed body')} \(blob changed on the server during pull\?\)$}, err)
    assert_equal ["ok.txt"], local_entries
    assert_empty tmp_leftovers
  end

  def test_blob_missing_after_listing_fails_with_the_server_status
    @fake = FakeServer.new("GET /blobs" => [200, fake_listing(["vanished.txt", "gone"])])
    status, _out, err = pull(@dir, @fake.url)
    assert_equal 1, status
    assert_match(%r{^syncbox: GET /blobs/vanished\.txt: server responded 404: not_found$}, err)
    assert_empty local_entries
    assert_empty tmp_leftovers
  end

  def test_malformed_listing_entry_is_an_error
    @fake = FakeServer.new("GET /blobs" => [200, JSON.generate([{ "size" => 1 }])])
    status, _out, err = pull(@dir, @fake.url)
    assert_equal 1, status
    assert_match(%r{^syncbox: GET /blobs: malformed entry in server listing: }, err)
  end

  # --- bin/syncbox как отдельный процесс -----------------------------------

  def run_bin(*args, env: {})
    base_env = { "SYNCBOX_SERVER" => nil }
    Open3.capture3(base_env.merge(env), CLIENT_BIN, *args)
  end

  def test_bin_pull_with_server_from_environment
    @server.put("a.txt", "alpha")
    out, err, status = run_bin("pull", @dir, env: { "SYNCBOX_SERVER" => @server.url })
    assert_equal 0, status.exitstatus, err
    assert_equal ["downloaded a.txt (5 bytes)", "pull complete: 1 downloaded, 0 unchanged, 1 files total"], out.lines(chomp: true)
    assert_equal "alpha", local("a.txt")
  end

  def test_bin_pull_exit_codes
    _out, err, status = run_bin("pull", @dir)
    assert_equal 2, status.exitstatus
    assert_match(/--server is required/, err)

    _out, err, status = run_bin("pull", @dir, "--server", "http://127.0.0.1:#{free_port}")
    assert_equal 1, status.exitstatus
    assert_match(/cannot connect to server/, err)
  end
end
