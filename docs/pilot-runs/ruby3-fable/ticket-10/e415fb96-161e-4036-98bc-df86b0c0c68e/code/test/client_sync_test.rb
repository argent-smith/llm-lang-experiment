# frozen_string_literal: true

require "test_helper"
require "open3"
require "stringio"

# syncbox sync против настоящего сервера: перенос в обе стороны, учёт
# последнего общего состояния (.syncbox/state.json), правило разрешения
# конфликтов (более свежий mtime, при равенстве — локальная версия),
# отсутствие удалений, коды возврата — через Syncbox::Client::CLI в процессе
# и через bin/syncbox отдельным процессом. Недоверенные ответы (битый
# modified_at, доли секунды в modified_at) — против TestSupport::FakeServer.
class ClientSyncTest < Minitest::Test
  include Syncbox::TestSupport

  FakeServer = Syncbox::TestSupport::FakeServer
  STATE_FILE = ".syncbox/state.json"

  def setup
    @tmp = Dir.mktmpdir("syncbox-sync")
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

  def write(rel, content = rel, mtime: nil)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    File.utime(mtime, mtime, path) if mtime
    path
  end

  def local(rel)
    File.binread(File.join(@dir, rel))
  end

  def set_mtime(rel, time)
    File.utime(time, time, File.join(@dir, rel))
  end

  # Запуск CLI в процессе: [status, stdout, stderr].
  def run_cli(argv, env = {})
    out = StringIO.new
    err = StringIO.new
    status = Syncbox::Client::CLI.run(argv, env: env, out: out, err: err)
    [status, out.string, err.string]
  end

  def sync(dir = @dir, server = @server.url)
    run_cli(["sync", dir, "--server", server])
  end

  # Успешный sync; возвращает строки stdout.
  def sync!(dir = @dir, server = @server.url)
    status, out, err = sync(dir, server)
    assert_equal 0, status, err
    assert_equal "", err
    out.lines(chomp: true)
  end

  # Относительные пути всех файлов под @dir, кроме служебного каталога.
  def local_entries
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir)
       .reject { |rel| rel == "." || rel == ".syncbox" || rel.start_with?(".syncbox/") || File.directory?(File.join(@dir, rel)) }
       .sort
  end

  def local_mtimes
    local_entries.to_h { |rel| [rel, File.mtime(File.join(@dir, rel))] }
  end

  def server_mtimes
    @server.keys.to_h { |key| [key, File.mtime(File.join(@server.data_dir, key))] }
  end

  def server_modified_at(key)
    Time.iso8601(@server.list.find { |meta| meta["key"] == key }.fetch("modified_at"))
  end

  # key → sha256 из манифеста, или nil, если манифеста нет.
  def state
    path = File.join(@dir, STATE_FILE)
    return nil unless File.exist?(path)

    payload = JSON.parse(File.read(path))
    assert_equal 1, payload["version"]
    payload["files"].transform_values { |entry| entry.fetch("sha256") }
  end

  def sha(content)
    Digest::SHA256.hexdigest(content)
  end

  def iso(time)
    Time.at(time.to_i).utc.iso8601
  end

  def summary(uploaded, downloaded, unchanged, conflicts)
    "sync complete: #{uploaded} uploaded, #{downloaded} downloaded, #{unchanged} unchanged, " \
      "#{uploaded + downloaded + unchanged} files total, #{conflicts} conflicts resolved"
  end

  # --- перенос в одну сторону ------------------------------------------------

  def test_local_only_file_appears_on_the_server
    write("docs/new-local.txt", "hello")
    assert_equal ["uploaded docs/new-local.txt (5 bytes; only local)", summary(1, 0, 0, 0)], sync!
    assert_equal "hello", @server.blob("docs/new-local.txt")
    assert_equal({ "docs/new-local.txt" => sha("hello") }, state)
  end

  def test_server_only_blob_appears_locally_with_its_subdirectories
    @server.put("docs/sub/deep/remote.txt", "from server")
    assert_equal ["downloaded docs/sub/deep/remote.txt (11 bytes; only on server)", summary(0, 1, 0, 0)], sync!
    assert_equal "from server", local("docs/sub/deep/remote.txt")
    assert_equal ["docs/sub/deep/remote.txt"], local_entries
    assert_equal({ "docs/sub/deep/remote.txt" => sha("from server") }, state)
  end

  def test_file_changed_only_locally_is_uploaded_even_if_the_server_copy_is_newer_by_mtime
    write("x.txt", "v1")
    sync!
    # локальная правка с mtime в прошлом: сервер по времени «новее», но он не
    # менялся относительно общего состояния — правило mtime не применяется
    write("x.txt", "v2-local", mtime: Time.now - 3600)
    assert_equal ["uploaded x.txt (8 bytes; changed locally)", summary(1, 0, 0, 0)], sync!
    assert_equal "v2-local", @server.blob("x.txt")
    assert_equal "v2-local", local("x.txt")
    assert_equal sha("v2-local"), state["x.txt"]
  end

  def test_file_changed_only_on_the_server_is_downloaded_even_if_the_local_copy_is_newer_by_mtime
    write("x.txt", "v1")
    sync!
    set_mtime("x.txt", Time.now + 3600) # только mtime, содержимое прежнее
    @server.put("x.txt", "v2-server")
    assert_equal ["downloaded x.txt (9 bytes; changed on server)", summary(0, 1, 0, 0)], sync!
    assert_equal "v2-server", local("x.txt")
    assert_equal "v2-server", @server.blob("x.txt")
    assert_equal sha("v2-server"), state["x.txt"]
  end

  def test_same_content_on_both_sides_is_unchanged_and_recorded_as_common_state
    write("same.txt", "same")
    @server.put("same.txt", "same")
    sleep 0.01
    FileUtils.touch(File.join(@dir, "same.txt"))
    before = local_mtimes
    assert_equal ["unchanged same.txt", summary(0, 0, 1, 0)], sync!
    assert_equal before, local_mtimes
    assert_equal({ "same.txt" => sha("same") }, state)
  end

  # --- конфликты -------------------------------------------------------------

  def test_conflict_with_a_newer_local_file_is_won_by_the_local_version
    write("c.txt", "base")
    sync!
    @server.put("c.txt", "server edit")
    local_time = Time.now + 3600
    write("c.txt", "local edit", mtime: local_time)

    lines = sync!
    assert_equal "uploaded c.txt (10 bytes; conflict: local #{iso(local_time)} is newer than server #{iso(server_modified_at('c.txt'))})",
                 lines[0]
    assert_equal summary(1, 0, 0, 1), lines[1]
    assert_equal "local edit", @server.blob("c.txt")
    assert_equal "local edit", local("c.txt")
    assert_equal sha("local edit"), state["c.txt"]
  end

  def test_conflict_with_a_newer_server_blob_is_won_by_the_server_version
    write("c.txt", "base")
    sync!
    local_time = Time.now - 3600
    write("c.txt", "local edit", mtime: local_time)
    @server.put("c.txt", "server edit")
    server_time = server_modified_at("c.txt")

    lines = sync!
    assert_equal "downloaded c.txt (11 bytes; conflict: server #{iso(server_time)} is newer than local #{iso(local_time)})", lines[0]
    assert_equal summary(0, 1, 0, 1), lines[1]
    assert_equal "server edit", local("c.txt")
    assert_equal "server edit", @server.blob("c.txt"), "the losing local version is not uploaded"
    assert_equal sha("server edit"), state["c.txt"]
  end

  def test_conflict_with_equal_mtime_is_won_by_the_local_version
    write("c.txt", "base")
    sync!
    @server.put("c.txt", "server edit")
    server_time = server_modified_at("c.txt")
    write("c.txt", "local edit", mtime: server_time)

    lines = sync!
    assert_equal "uploaded c.txt (10 bytes; conflict: same mtime #{iso(server_time)}, local wins)", lines[0]
    assert_equal summary(1, 0, 0, 1), lines[1]
    assert_equal "local edit", @server.blob("c.txt")
    assert_equal "local edit", local("c.txt")
  end

  def test_sub_second_local_mtime_difference_is_equality_at_the_servers_precision
    write("c.txt", "base")
    sync!
    @server.put("c.txt", "server edit")
    server_time = server_modified_at("c.txt") # целые секунды
    write("c.txt", "local edit", mtime: server_time + 0.4)
    lines = sync!
    assert_equal "uploaded c.txt (10 bytes; conflict: same mtime #{iso(server_time)}, local wins)", lines[0]
    assert_equal "local edit", @server.blob("c.txt")

    # а на целую секунду — уже не равенство
    @server.put("c.txt", "server edit 2")
    server_time = server_modified_at("c.txt")
    write("c.txt", "local edit 2", mtime: server_time - 1)
    lines = sync!
    assert_equal "downloaded c.txt (13 bytes; conflict: server #{iso(server_time)} is newer than local #{iso(server_time - 1)})", lines[0]
    assert_equal "server edit 2", local("c.txt")
  end

  def test_first_sync_with_differing_content_and_no_common_state_follows_the_mtime_rule
    write("older-local.txt", "local", mtime: Time.now - 3600)
    write("newer-local.txt", "local", mtime: Time.now + 3600)
    @server.put("older-local.txt", "server")
    @server.put("newer-local.txt", "server")
    refute File.exist?(File.join(@dir, STATE_FILE))

    lines = sync!
    assert_match(/\Auploaded newer-local\.txt \(5 bytes; conflict, never synced before: local .* is newer than server .*\)\z/, lines[0])
    assert_match(/\Adownloaded older-local\.txt \(6 bytes; conflict, never synced before: server .* is newer than local .*\)\z/, lines[1])
    assert_equal summary(1, 1, 0, 2), lines[2]
    assert_equal "local", @server.blob("newer-local.txt")
    assert_equal "server", local("older-local.txt")
    assert_equal({ "newer-local.txt" => sha("local"), "older-local.txt" => sha("server") }, state)
  end

  # --- удаления не распространяются ------------------------------------------

  def test_sync_never_deletes_on_either_side
    write("deleted-locally.txt", "A")
    write("deleted-on-server.txt", "B")
    write("kept.txt", "C")
    sync!
    File.delete(File.join(@dir, "deleted-locally.txt"))
    @server.http.delete("/blobs/deleted-on-server.txt")
    assert_equal %w[deleted-locally.txt kept.txt], @server.keys

    assert_equal ["downloaded deleted-locally.txt (1 bytes; only on server)",
                  "uploaded deleted-on-server.txt (1 bytes; only local)",
                  "unchanged kept.txt",
                  summary(1, 1, 1, 0)], sync!
    assert_equal "A", local("deleted-locally.txt")
    assert_equal "B", @server.blob("deleted-on-server.txt")
    assert_equal %w[deleted-locally.txt deleted-on-server.txt kept.txt], @server.keys
    assert_equal %w[deleted-locally.txt deleted-on-server.txt kept.txt], local_entries
  end

  # --- повторный запуск, манифест ----------------------------------------------

  def test_second_sync_transfers_nothing_and_touches_nothing
    write("a.txt", "alpha")
    write("d/b.bin", "\x00\xff".b)
    @server.put("c.txt", "gamma")
    assert_equal summary(2, 1, 0, 0), sync!.last
    local_before = local_mtimes
    server_before = server_mtimes
    state_mtime = File.mtime(File.join(@dir, STATE_FILE))

    assert_equal ["unchanged a.txt", "unchanged c.txt", "unchanged d/b.bin", summary(0, 0, 3, 0)], sync!
    assert_equal local_before, local_mtimes
    assert_equal server_before, server_mtimes
    assert_equal state_mtime, File.mtime(File.join(@dir, STATE_FILE)), "an unchanged manifest is not rewritten"
    assert_equal({ "a.txt" => sha("alpha"), "c.txt" => sha("gamma"), "d/b.bin" => sha("\x00\xff".b) }, state)
  end

  def test_state_dir_is_invisible_to_push_status_and_sync_and_server_blobs_under_it_are_skipped
    write("a.txt", "alpha")
    sync!
    assert File.file?(File.join(@dir, STATE_FILE))
    assert_equal ["a.txt"], @server.keys, "the manifest is not uploaded"

    status, out, err = run_cli(["push", @dir, "--server", @server.url])
    assert_equal 0, status, err
    assert_equal ["unchanged a.txt", "push complete: 0 uploaded, 1 unchanged, 1 files total"], out.lines(chomp: true)

    @server.put(".syncbox/state.json", "{\"version\":1,\"files\":{}}")
    status, out, err = run_cli(["status", @dir, "--server", @server.url])
    assert_equal 0, status, err
    assert_equal ["syncbox: skipping .syncbox/state.json: .syncbox/ is reserved for the client's sync state"], err.lines(chomp: true)
    assert_equal ["unchanged a.txt", "status: in sync, 1 unchanged, nothing to upload or download (dry run, nothing changed)"],
                 out.lines(chomp: true)

    status, out, err = sync
    assert_equal 0, status, err
    assert_equal ["syncbox: skipping .syncbox/state.json: .syncbox/ is reserved for the client's sync state"], err.lines(chomp: true)
    assert_equal ["unchanged a.txt", summary(0, 0, 1, 0)], out.lines(chomp: true)
    assert_equal({ "a.txt" => sha("alpha") }, state, "the server cannot overwrite the client's manifest")
  end

  def test_keys_gone_from_both_sides_are_dropped_from_the_state
    write("gone.txt", "g")
    write("stays.txt", "s")
    sync!
    File.delete(File.join(@dir, "gone.txt"))
    @server.http.delete("/blobs/gone.txt")
    sync!
    assert_equal({ "stays.txt" => sha("s") }, state)
  end

  def test_state_is_saved_for_files_transferred_before_a_failure
    write("a.txt", "alpha")
    FileUtils.mkdir_p(File.join(@dir, "zz-dir"))
    @server.put("zz-dir", "a file on the server where a directory is locally")
    status, out, err = sync
    assert_equal 1, status
    assert_equal ["uploaded a.txt (5 bytes; only local)"], out.lines(chomp: true)
    assert_match(%r{^syncbox: cannot write zz-dir: a directory is in the way at .*/zz-dir$}, err)
    assert_equal "alpha", @server.blob("a.txt")
    assert_equal({ "a.txt" => sha("alpha") }, state)
  end

  def test_corrupt_state_file_fails_with_exit_1_before_touching_anything
    write("a.txt", "alpha")
    FileUtils.mkdir_p(File.join(@dir, ".syncbox"))
    File.write(File.join(@dir, STATE_FILE), "{not json")
    status, out, err = sync
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: sync state .*/\.syncbox/state\.json is corrupt \(.*\); delete it to start over$}, err)
    assert_empty @server.keys
  end

  def test_mixed_tree_is_processed_in_key_order
    write("a/local-only.txt", "L")
    write("b/same.bin", "\x00\xff".b)
    write("c/base.txt", "base")
    write("каталог/файл.txt", "unicode")
    @server.put("b/same.bin", "\x00\xff".b)
    @server.put("d/server-only.txt", "S")
    @server.put("каталог/файл.txt", "unicode")
    sync!
    write("c/base.txt", "local edit", mtime: Time.now - 3600)
    @server.put("c/base.txt", "server edit")
    write("e/converged.txt", "same text")
    @server.put("e/converged.txt", "same text")

    lines = sync!
    assert_equal "unchanged a/local-only.txt", lines[0]
    assert_equal "unchanged b/same.bin", lines[1]
    assert_match(/\Adownloaded c\/base\.txt \(11 bytes; conflict: server .* is newer than local .*\)\z/, lines[2])
    assert_equal "unchanged d/server-only.txt", lines[3]
    assert_equal "unchanged e/converged.txt", lines[4]
    assert_equal "unchanged каталог/файл.txt", lines[5]
    assert_equal summary(0, 1, 5, 1), lines[6]
    assert_equal "server edit", local("c/base.txt")
    assert_equal %w[a/local-only.txt b/same.bin c/base.txt d/server-only.txt e/converged.txt каталог/файл.txt], state.keys.sort
  end

  def test_large_files_round_trip_in_both_directions
    up = Random.new(3).bytes(2 * 1024 * 1024 + 7)
    down = Random.new(4).bytes(2 * 1024 * 1024 + 11)
    write("up.bin", up)
    @server.put("down.bin", down)
    assert_equal summary(1, 1, 0, 0), sync!.last
    assert_equal up, @server.blob("up.bin")
    assert_equal down, local("down.bin")
  end

  def test_two_directories_converge_through_the_server
    other = File.join(@tmp, "other")
    FileUtils.mkdir_p(other)
    write("a.txt", "from first")
    File.binwrite(File.join(other, "b.txt"), "from second")

    sync!
    sync!(other)
    sync!
    assert_equal "from second", local("b.txt")
    assert_equal "from first", File.binread(File.join(other, "a.txt"))

    # правка в первом каталоге доезжает до второго без конфликта
    write("a.txt", "edited in first", mtime: Time.now - 7200)
    sync!
    status, out, err = sync(other)
    assert_equal 0, status, err
    assert_includes out.lines(chomp: true), "downloaded a.txt (15 bytes; changed on server)"
    assert_equal "edited in first", File.binread(File.join(other, "a.txt"))
  end

  # --- ошибки ------------------------------------------------------------------

  def test_unreachable_server_fails_with_a_message_and_exit_1
    write("a.txt", "a")
    port = free_port
    status, out, err = sync(@dir, "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: cannot connect to server http://127\.0\.0\.1:#{port}: }, err)
    refute File.exist?(File.join(@dir, STATE_FILE)), "no manifest is written when nothing was synced"
  end

  def test_missing_directory_fails_with_exit_1_before_touching_the_network
    @server.stop
    status, out, err = sync(File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{^syncbox: directory not found: .*nope$}, err)
  end

  def test_traversal_keys_from_the_server_are_refused
    @fake = FakeServer.new("GET /blobs" => [200, FakeServer.listing(["../escape.txt", "evil"])])
    status, _out, err = sync(@dir, @fake.url)
    assert_equal 1, status
    assert_match(/^syncbox: refusing to sync "\.\.\/escape\.txt": key contains a '\.' or '\.\.' segment$/, err)
    assert_equal ["GET /blobs"], @fake.requests
    assert_empty local_entries
  end

  def test_conflict_with_malformed_or_missing_modified_at_is_an_error
    write("x.txt", "local", mtime: Time.now - 3600)
    @fake = FakeServer.new("GET /blobs" => [200, JSON.generate([{ "key" => "x.txt", "size" => 6, "sha256" => sha("server"), "modified_at" => "yesterday" }])])
    status, _out, err = sync(@dir, @fake.url)
    assert_equal 1, status
    assert_match(%r{^syncbox: GET /blobs: entry "x\.txt" has malformed modified_at "yesterday": }, err)
    assert_equal "local", local("x.txt")

    @fake.stop
    @fake = FakeServer.new("GET /blobs" => [200, JSON.generate([{ "key" => "x.txt", "size" => 6, "sha256" => sha("server") }])])
    status, _out, err = sync(@dir, @fake.url)
    assert_equal 1, status
    assert_match(%r{^syncbox: GET /blobs: entry "x\.txt" has no modified_at, cannot resolve the conflict$}, err)
  end

  def test_fractional_modified_at_is_compared_at_its_own_precision
    write("x.txt", "local", mtime: Time.at(Rational(1_767_225_600_9, 10))) # 2026-01-01T00:00:00.9Z
    listing = JSON.generate([{ "key" => "x.txt", "size" => 6, "sha256" => sha("server"), "modified_at" => "2026-01-01T00:00:00.95Z" }])
    @fake = FakeServer.new("GET /blobs" => [200, listing], "GET /blobs/x.txt" => [200, "server"])
    status, out, err = sync(@dir, @fake.url)
    assert_equal 0, status, err
    assert_equal "downloaded x.txt (6 bytes; conflict, never synced before: server 2026-01-01T00:00:00.95Z is newer than local 2026-01-01T00:00:00.90Z)",
                 out.lines(chomp: true)[0]
    assert_equal "server", local("x.txt")
  end

  # --- bin/syncbox как отдельный процесс -----------------------------------

  def run_bin(*args, env: {})
    base_env = { "SYNCBOX_SERVER" => nil }
    Open3.capture3(base_env.merge(env), CLIENT_BIN, *args)
  end

  def test_bin_sync_with_server_from_environment
    write("a.txt", "alpha")
    @server.put("b.txt", "beta")
    out, err, status = run_bin("sync", @dir, env: { "SYNCBOX_SERVER" => @server.url })
    assert_equal 0, status.exitstatus, err
    assert_equal "", err
    assert_equal ["uploaded a.txt (5 bytes; only local)", "downloaded b.txt (4 bytes; only on server)", summary(1, 1, 0, 0)],
                 out.lines(chomp: true)
    assert_equal "alpha", @server.blob("a.txt")
    assert_equal "beta", local("b.txt")
  end

  def test_bin_sync_exit_codes
    _out, err, status = run_bin("sync", @dir)
    assert_equal 2, status.exitstatus
    assert_match(/--server is required/, err)

    _out, err, status = run_bin("sync", @dir, "--server", "http://127.0.0.1:#{free_port}")
    assert_equal 1, status.exitstatus
    assert_match(/cannot connect to server/, err)
  end
end
