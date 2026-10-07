# frozen_string_literal: true

require "test_helper"
require "open3"
require "stringio"

# Сетевые ошибки и частичные сбои клиента (раздел «Коды возврата и ошибки»
# спецификации) для всех четырёх команд. Недоступный сервер — соединение
# отклонено, имя не резолвится, таймаут соединения, таймаут ответа, обрыв
# соединения — понятное сообщение с причиной в stderr, код 1, без
# зависания. Частичный сбой — один файл из нескольких упал (5xx или 4xx на
# конкретный key, обрыв или таймаут конкретного запроса, нечитаемый
# локальный файл) — остальные файлы обработаны до конца, в stderr — отчёт
# по упавшим, код 1. Сетевые сбои воспроизводятся поддельным сервером
# (TestSupport::FakeServer); таймауты для тестов укорочены подменой
# Api.timeouts.
class ClientFailuresTest < Minitest::Test
  include Syncbox::TestSupport

  Api = Syncbox::Client::Api
  FakeServer = Syncbox::TestSupport::FakeServer
  COMMANDS = %w[push pull sync status].freeze
  SHORT_TIMEOUTS = { open: 10, read: 1, write: 1 }.freeze

  def setup
    @tmp = Dir.mktmpdir("syncbox-failures")
    @dir = File.join(@tmp, "local")
    FileUtils.mkdir_p(@dir)
    @server = nil
    @fake = nil
  end

  def teardown
    @server&.stop
    @fake&.stop
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def start_server
    @server = Syncbox::TestSupport::ServerProcess.new(File.join(@tmp, "data"))
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

  # Относительные пути всех файлов под @dir, кроме служебного каталога.
  def local_entries
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir)
       .reject { |rel| rel == "." || rel == ".syncbox" || rel.start_with?(".syncbox/") || File.directory?(File.join(@dir, rel)) }
       .sort
  end

  def tmp_leftovers
    Dir.glob("**/.syncbox-*.tmp", File::FNM_DOTMATCH, base: @dir)
  end

  # key → sha256 из манифеста sync, или nil, если манифеста нет.
  def state
    path = File.join(@dir, ".syncbox", "state.json")
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))["files"].transform_values { |entry| entry.fetch("sha256") }
  end

  def sha(content)
    Digest::SHA256.hexdigest(content)
  end

  # Запуск CLI в процессе: [status, stdout, stderr].
  def run_cli(argv, env = {})
    out = StringIO.new
    err = StringIO.new
    status = Syncbox::Client::CLI.run(argv, env: env, out: out, err: err)
    [status, out.string, err.string]
  end

  def run_command(command, server, dir: @dir, timeouts: nil)
    argv = [command, dir, "--server", server]
    return run_cli(argv) unless timeouts

    with_timeouts(timeouts) { run_cli(argv) }
  end

  # Подменяет Api.timeouts на время блока (флагов для таймаутов у клиента
  # нет — спецификация их не предусматривает).
  def with_timeouts(timeouts)
    original = Api.method(:timeouts)
    Api.define_singleton_method(:timeouts) { timeouts }
    yield
  ensure
    Api.define_singleton_method(:timeouts, original) if original
  end

  def run_bin(*args, env: {})
    Open3.capture3({ "SYNCBOX_SERVER" => nil }.merge(env), CLIENT_BIN, *args)
  end

  # [результат блока, секунды].
  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def listing(*entries)
    FakeServer.listing(*entries)
  end

  # --- сервер недоступен ------------------------------------------------------

  def test_connection_refused_fails_every_command_quickly_with_the_reason
    write("a.txt", "a")
    port = free_port
    COMMANDS.each do |command|
      (status, out, err), seconds = timed { run_command(command, "http://127.0.0.1:#{port}") }
      assert_equal 1, status, command
      assert_equal "", out, command
      assert_equal 1, err.lines.size, "#{command}: #{err}"
      assert_match(%r{\Asyncbox: cannot connect to server http://127\.0\.0\.1:#{port}: Connection refused}, err, command)
      assert_operator seconds, :<, 5, "#{command} must fail fast, not hang"
    end
    assert_equal ["a.txt"], local_entries, "nothing is written locally"
    refute File.exist?(File.join(@dir, ".syncbox")), "sync writes no state when nothing was synced"
  end

  def test_unresolvable_host_fails_with_the_resolver_error
    write("a.txt", "a")
    (status, out, err), seconds = timed { run_command("push", "http://nonexistent.invalid:8080", timeouts: { open: 5, read: 5, write: 5 }) }
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot connect to server http://nonexistent\.invalid:8080: \S.*$}, err)
    assert_operator seconds, :<, 15, "name resolution is bounded by the open timeout"
  end

  def test_connect_timeout_is_bounded_by_the_open_timeout
    # Немаршрутизируемый адрес: SYN уходит в никуда, срабатывает таймаут
    # соединения. В окружении без внешней сети ОС может отказать сразу —
    # тогда это тоже «cannot connect», просто с другой причиной.
    (status, out, err), seconds = timed { run_command("status", "http://10.255.255.1:9", timeouts: { open: 2, read: 2, write: 2 }) }
    assert_equal 1, status
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot connect to server http://10\.255\.255\.1:9: (connection timed out after 2s|\S.*)$}, err)
    assert_operator seconds, :<, 10, "connecting must give up after the open timeout"
  end

  def test_server_that_accepts_but_never_responds_fails_every_command_after_the_read_timeout
    write("a.txt", "a")
    @fake = FakeServer.new("GET /blobs" => :hang)
    COMMANDS.each do |command|
      (status, out, err), seconds = timed { run_command(command, @fake.url, timeouts: SHORT_TIMEOUTS) }
      assert_equal 1, status, command
      assert_equal "", out, command
      assert_equal ["syncbox: GET /blobs: request to #{@fake.url} failed: server did not respond within 1s (read timeout)"],
                   err.lines(chomp: true), command
      assert_operator seconds, :>=, 1, command
      assert_operator seconds, :<, 10, "#{command} must give up after the read timeout, not hang"
    end
    assert_equal ["a.txt"], local_entries
    refute File.exist?(File.join(@dir, ".syncbox"))
  end

  def test_server_that_drops_the_connection_fails_with_the_reason
    @fake = FakeServer.new("GET /blobs" => :drop)
    status, out, err = run_command("pull", @fake.url)
    assert_equal 1, status
    assert_equal "", out
    assert_equal ["syncbox: GET /blobs: request to #{@fake.url} failed: server closed the connection without a complete response"],
                 err.lines(chomp: true)
  end

  def test_server_dying_mid_push_aborts_with_cannot_connect_after_the_files_already_transferred
    write("a.txt", "a")
    write("b.txt", "b")
    write("c.txt", "c")
    @fake = FakeServer.new("GET /blobs" => [200, "[]"],
                           "PUT /blobs/a.txt" => FakeServer.put_ok("a.txt"),
                           "PUT /blobs/b.txt" => lambda { |body|
                             @fake.refuse_connections
                             FakeServer.put_ok("b.txt").call(body)
                           })
    status, out, err = run_command("push", @fake.url)
    assert_equal 1, status
    assert_equal ["uploaded a.txt (1 bytes)", "uploaded b.txt (1 bytes)"], out.lines(chomp: true)
    assert_match(%r{\Asyncbox: cannot connect to server #{Regexp.escape(@fake.url)}: Connection refused}, err)
    assert_equal ["GET /blobs", "PUT /blobs/a.txt", "PUT /blobs/b.txt"], @fake.requests
  end

  def test_api_distinguishes_a_failed_request_from_an_unreachable_server
    @fake = FakeServer.new("GET /blobs" => :drop)
    Api.open(URI(@fake.url)) do |api|
      error = assert_raises(Syncbox::Client::Error) { api.list_blobs }
      refute_kind_of Syncbox::Client::ServerUnreachable, error
      assert_match(/server closed the connection/, error.message)

      @fake.refuse_connections
      error = assert_raises(Syncbox::Client::ServerUnreachable) { api.list_blobs }
      assert_match(/\Acannot connect to server .*: Connection refused/, error.message)
    end
  end

  # --- частичный сбой: push ---------------------------------------------------

  def test_push_continues_past_a_key_the_real_server_rejects_and_reports_it
    start_server
    write("a.txt", "a")
    write(".syncbox-tmp/reserved", "x")
    write("z.txt", "z")
    status, out, err = run_command("push", @server.url)
    assert_equal 1, status
    assert_equal ["failed .syncbox-tmp/reserved", "uploaded a.txt (1 bytes)", "uploaded z.txt (1 bytes)",
                  "push incomplete: 2 uploaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    reason = "PUT /blobs/.syncbox-tmp/reserved: server responded 400: key uses reserved name .syncbox-tmp"
    assert_equal ["syncbox: failed .syncbox-tmp/reserved: #{reason}",
                  "syncbox: push failed for 1 of 3 files:",
                  "  .syncbox-tmp/reserved: #{reason}"], err.lines(chomp: true)
    assert_equal %w[a.txt z.txt], @server.keys
  end

  def test_push_continues_past_a_5xx_on_one_key
    write("a.txt", "a")
    write("b.txt", "b")
    write("c.txt", "c")
    @fake = FakeServer.new("GET /blobs" => [200, "[]"],
                           "PUT /blobs/a.txt" => FakeServer.put_ok("a.txt"),
                           "PUT /blobs/b.txt" => [500, "{\"error\":\"internal\",\"message\":\"disk on fire\"}"],
                           "PUT /blobs/c.txt" => FakeServer.put_ok("c.txt"))
    status, out, err = run_command("push", @fake.url)
    assert_equal 1, status
    assert_equal ["uploaded a.txt (1 bytes)", "failed b.txt", "uploaded c.txt (1 bytes)",
                  "push incomplete: 2 uploaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    assert_equal ["syncbox: failed b.txt: PUT /blobs/b.txt: server responded 500: disk on fire",
                  "syncbox: push failed for 1 of 3 files:",
                  "  b.txt: PUT /blobs/b.txt: server responded 500: disk on fire"], err.lines(chomp: true)
    assert_equal ["GET /blobs", "PUT /blobs/a.txt", "PUT /blobs/b.txt", "PUT /blobs/c.txt"], @fake.requests
  end

  def test_push_continues_past_a_dropped_connection_on_one_key
    write("a.txt", "a")
    write("b.txt", "b")
    write("c.txt", "c")
    @fake = FakeServer.new("GET /blobs" => [200, "[]"],
                           "PUT /blobs/a.txt" => FakeServer.put_ok("a.txt"),
                           "PUT /blobs/b.txt" => :drop,
                           "PUT /blobs/c.txt" => FakeServer.put_ok("c.txt"))
    status, out, err = run_command("push", @fake.url)
    assert_equal 1, status
    assert_equal ["uploaded a.txt (1 bytes)", "failed b.txt", "uploaded c.txt (1 bytes)",
                  "push incomplete: 2 uploaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    reason = "PUT /blobs/b.txt: request to #{@fake.url} failed: server closed the connection without a complete response"
    assert_equal ["syncbox: failed b.txt: #{reason}", "syncbox: push failed for 1 of 3 files:", "  b.txt: #{reason}"],
                 err.lines(chomp: true)
    assert_equal ["GET /blobs", "PUT /blobs/a.txt", "PUT /blobs/b.txt", "PUT /blobs/c.txt"], @fake.requests
  end

  def test_push_continues_past_a_request_timeout_on_one_key
    write("a.txt", "a")
    write("b.txt", "b")
    write("c.txt", "c")
    @fake = FakeServer.new("GET /blobs" => [200, "[]"],
                           "PUT /blobs/a.txt" => FakeServer.put_ok("a.txt"),
                           "PUT /blobs/b.txt" => :hang,
                           "PUT /blobs/c.txt" => FakeServer.put_ok("c.txt"))
    (status, out, err), seconds = timed { run_command("push", @fake.url, timeouts: SHORT_TIMEOUTS) }
    assert_equal 1, status
    assert_equal ["uploaded a.txt (1 bytes)", "failed b.txt", "uploaded c.txt (1 bytes)",
                  "push incomplete: 2 uploaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    reason = "PUT /blobs/b.txt: request to #{@fake.url} failed: server did not respond within 1s (read timeout)"
    assert_equal ["syncbox: failed b.txt: #{reason}", "syncbox: push failed for 1 of 3 files:", "  b.txt: #{reason}"],
                 err.lines(chomp: true)
    assert_operator seconds, :<, 10
  end

  def test_push_continues_past_an_unreadable_local_file
    skip "root ignores file permissions" if Process.uid.zero?
    start_server
    write("a.txt", "a")
    secret = write("secret.txt", "s")
    write("z.txt", "z")
    File.chmod(0o000, secret)
    status, out, err = run_command("push", @server.url)
    assert_equal 1, status
    assert_equal ["uploaded a.txt (1 bytes)", "failed secret.txt", "uploaded z.txt (1 bytes)",
                  "push incomplete: 2 uploaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    assert_match(/\Asyncbox: failed secret\.txt: Permission denied .*secret\.txt\n/, err)
    assert_match(/^syncbox: push failed for 1 of 3 files:\n  secret\.txt: Permission denied .*secret\.txt$/, err)
    assert_equal %w[a.txt z.txt], @server.keys
  ensure
    File.chmod(0o644, secret) if secret
  end

  def test_successful_push_output_and_exit_code_are_unchanged
    start_server
    write("a.txt", "a")
    status, out, err = run_command("push", @server.url)
    assert_equal 0, status
    assert_equal "", err
    assert_equal ["uploaded a.txt (1 bytes)", "push complete: 1 uploaded, 0 unchanged, 1 files total"], out.lines(chomp: true)
  end

  # --- частичный сбой: pull ---------------------------------------------------

  def test_pull_continues_past_a_5xx_on_one_blob
    @fake = FakeServer.new("GET /blobs" => [200, listing(["a.txt", "A"], ["b.txt", "B"], ["c.txt", "C"])],
                           "GET /blobs/a.txt" => [200, "A"],
                           "GET /blobs/b.txt" => [503, "unavailable"],
                           "GET /blobs/c.txt" => [200, "C"])
    status, out, err = run_command("pull", @fake.url)
    assert_equal 1, status
    assert_equal ["downloaded a.txt (1 bytes)", "failed b.txt", "downloaded c.txt (1 bytes)",
                  "pull incomplete: 2 downloaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    assert_equal ["syncbox: failed b.txt: GET /blobs/b.txt: server responded 503: unavailable",
                  "syncbox: pull failed for 1 of 3 files:",
                  "  b.txt: GET /blobs/b.txt: server responded 503: unavailable"], err.lines(chomp: true)
    assert_equal %w[a.txt c.txt], local_entries
    assert_equal "A", local("a.txt")
    assert_equal "C", local("c.txt")
    assert_empty tmp_leftovers
  end

  def test_pull_continues_past_a_dropped_connection_and_a_timeout_on_specific_blobs
    @fake = FakeServer.new("GET /blobs" => [200, listing(["a.txt", "A"], ["b.txt", "B"], ["c.txt", "C"], ["d.txt", "D"])],
                           "GET /blobs/a.txt" => [200, "A"],
                           "GET /blobs/b.txt" => :drop,
                           "GET /blobs/c.txt" => :hang,
                           "GET /blobs/d.txt" => [200, "D"])
    (status, out, err), seconds = timed { run_command("pull", @fake.url, timeouts: SHORT_TIMEOUTS) }
    assert_equal 1, status
    assert_equal ["downloaded a.txt (1 bytes)", "failed b.txt", "failed c.txt", "downloaded d.txt (1 bytes)",
                  "pull incomplete: 2 downloaded, 0 unchanged, 2 failed, 4 files total"], out.lines(chomp: true)
    dropped = "GET /blobs/b.txt: request to #{@fake.url} failed: server closed the connection without a complete response"
    timed_out = "GET /blobs/c.txt: request to #{@fake.url} failed: server did not respond within 1s (read timeout)"
    assert_equal ["syncbox: failed b.txt: #{dropped}", "syncbox: failed c.txt: #{timed_out}",
                  "syncbox: pull failed for 2 of 4 files:", "  b.txt: #{dropped}", "  c.txt: #{timed_out}"], err.lines(chomp: true)
    assert_equal %w[a.txt d.txt], local_entries
    assert_empty tmp_leftovers
    assert_operator seconds, :<, 10
  end

  def test_pull_continues_past_an_unwritable_target
    skip "root ignores directory permissions" if Process.uid.zero?
    start_server
    @server.put("ok.txt", "ok")
    @server.put("locked/x.txt", "x")
    @server.put("zz.txt", "zz")
    locked = File.join(@dir, "locked")
    FileUtils.mkdir_p(locked)
    File.chmod(0o500, locked)
    status, out, err = run_command("pull", @server.url)
    assert_equal 1, status
    assert_equal ["failed locked/x.txt", "downloaded ok.txt (2 bytes)", "downloaded zz.txt (2 bytes)",
                  "pull incomplete: 2 downloaded, 0 unchanged, 1 failed, 3 files total"], out.lines(chomp: true)
    assert_match(%r{\Asyncbox: failed locked/x\.txt: cannot write locked/x\.txt: Permission denied}, err)
    assert_match(%r{^syncbox: pull failed for 1 of 3 files:\n  locked/x\.txt: cannot write}, err)
    assert_equal %w[ok.txt zz.txt], local_entries
  ensure
    File.chmod(0o755, locked) if locked && File.directory?(locked)
  end

  # --- частичный сбой: sync ---------------------------------------------------

  def test_sync_continues_past_failures_in_both_directions_and_records_only_what_converged
    write("l.txt", "L")
    write("m.txt", "M")
    write("same.txt", "same")
    @fake = FakeServer.new("GET /blobs" => [200, listing(["s.txt", "S"], ["t.txt", "T"], ["same.txt", "same"])],
                           "PUT /blobs/l.txt" => FakeServer.put_ok("l.txt"),
                           "PUT /blobs/m.txt" => [500, "boom"],
                           "GET /blobs/s.txt" => [502, "bad gateway"],
                           "GET /blobs/t.txt" => [200, "T"])
    status, out, err = run_command("sync", @fake.url)
    assert_equal 1, status
    assert_equal ["uploaded l.txt (1 bytes; only local)", "failed m.txt", "failed s.txt", "unchanged same.txt",
                  "downloaded t.txt (1 bytes; only on server)",
                  "sync incomplete: 1 uploaded, 1 downloaded, 1 unchanged, 2 failed, 5 files total, 0 conflicts resolved"],
                 out.lines(chomp: true)
    assert_equal ["syncbox: failed m.txt: PUT /blobs/m.txt: server responded 500: boom",
                  "syncbox: failed s.txt: GET /blobs/s.txt: server responded 502: bad gateway",
                  "syncbox: sync failed for 2 of 5 files:",
                  "  m.txt: PUT /blobs/m.txt: server responded 500: boom",
                  "  s.txt: GET /blobs/s.txt: server responded 502: bad gateway"], err.lines(chomp: true)
    assert_equal ["GET /blobs", "PUT /blobs/l.txt", "PUT /blobs/m.txt", "GET /blobs/s.txt", "GET /blobs/t.txt"], @fake.requests
    assert_equal %w[l.txt m.txt same.txt t.txt], local_entries
    assert_equal "T", local("t.txt")
    assert_equal({ "l.txt" => sha("L"), "same.txt" => sha("same"), "t.txt" => sha("T") }, state,
                 "failed keys are not recorded as common state")
    assert_empty tmp_leftovers
  end

  def test_sync_keeps_the_old_common_state_for_a_failed_conflict_so_the_next_sync_resolves_it_again
    write("x.txt", "base")
    @fake = FakeServer.new("GET /blobs" => [200, listing(["x.txt", "base"])])
    status, _out, err = run_command("sync", @fake.url)
    assert_equal 0, status, err
    assert_equal({ "x.txt" => sha("base") }, state)
    @fake.stop

    # обе стороны изменились, сервер новее → скачивание, но GET падает
    write("x.txt", "local edit")
    File.utime(Time.now - 3600, Time.now - 3600, File.join(@dir, "x.txt"))
    server_listing = JSON.generate([{ "key" => "x.txt", "size" => 11, "sha256" => sha("server edit"),
                                      "modified_at" => (Time.now + 3600).utc.iso8601 }])
    @fake = FakeServer.new("GET /blobs" => [200, server_listing], "GET /blobs/x.txt" => [500, "boom"])
    status, out, err = run_command("sync", @fake.url)
    assert_equal 1, status
    assert_equal ["failed x.txt", "sync incomplete: 0 uploaded, 0 downloaded, 0 unchanged, 1 failed, 1 files total, 0 conflicts resolved"],
                 out.lines(chomp: true)
    assert_match(%r{\Asyncbox: failed x\.txt: GET /blobs/x\.txt: server responded 500: boom}, err)
    assert_equal "local edit", local("x.txt"), "the losing local version is untouched when the download fails"
    assert_equal({ "x.txt" => sha("base") }, state, "the old common state is kept for the failed key")
    @fake.stop

    # сервер ожил: тот же конфликт решается заново, сервер снова побеждает
    @fake = FakeServer.new("GET /blobs" => [200, server_listing], "GET /blobs/x.txt" => [200, "server edit"])
    status, out, err = run_command("sync", @fake.url)
    assert_equal 0, status, err
    assert_match(/\Adownloaded x\.txt \(11 bytes; conflict: server .* is newer than local .*\)$/, out)
    assert_equal "server edit", local("x.txt")
    assert_equal({ "x.txt" => sha("server edit") }, state)
  end

  def test_sync_continues_past_an_unreadable_local_file_without_overwriting_it
    skip "root ignores file permissions" if Process.uid.zero?
    start_server
    write("a.txt", "a")
    secret = write("secret.txt", "local secret")
    @server.put("secret.txt", "server version")
    @server.put("z.txt", "z")
    File.chmod(0o000, secret)
    status, out, err = run_command("sync", @server.url)
    assert_equal 1, status
    assert_equal ["uploaded a.txt (1 bytes; only local)", "failed secret.txt", "downloaded z.txt (1 bytes; only on server)",
                  "sync incomplete: 1 uploaded, 1 downloaded, 0 unchanged, 1 failed, 3 files total, 0 conflicts resolved"],
                 out.lines(chomp: true)
    assert_match(/\Asyncbox: failed secret\.txt: Permission denied .*secret\.txt\n/, err)
    assert_match(/^syncbox: sync failed for 1 of 3 files:\n  secret\.txt: Permission denied/, err)
    File.chmod(0o644, secret)
    assert_equal "local secret", local("secret.txt"), "an unreadable local file is never replaced by the server version"
    assert_equal "server version", @server.blob("secret.txt")
    assert_equal({ "a.txt" => sha("a"), "z.txt" => sha("z") }, state)
  ensure
    File.chmod(0o644, secret) if secret
  end

  # --- частичный сбой: status -------------------------------------------------

  def test_status_reports_an_unreadable_local_file_as_not_compared_and_still_compares_the_rest
    skip "root ignores file permissions" if Process.uid.zero?
    @fake = FakeServer.new("GET /blobs" => [200, listing(["b.txt", "b"], ["secret.txt", "s"])])
    write("a.txt", "a")
    secret = write("secret.txt", "s")
    File.chmod(0o000, secret)
    status, out, err = run_command("status", @fake.url)
    assert_equal 1, status
    assert_equal ["upload    a.txt (1 bytes; only local, not on server)",
                  "download  b.txt (1 bytes; only on server, not local)",
                  "failed    secret.txt (not compared, see stderr)",
                  "status: 1 failed (not compared), 1 to upload (1 only local), 1 to download (1 only on server), " \
                  "0 differing on both sides, 0 unchanged, 3 files total (dry run, nothing changed)"], out.lines(chomp: true)
    assert_match(/\Asyncbox: failed secret\.txt: Permission denied .*secret\.txt\n/, err)
    assert_match(/^syncbox: status failed for 1 of 3 files:\n  secret\.txt: Permission denied/, err)
    assert_equal ["GET /blobs"], @fake.requests, "status still sends nothing but the listing"
  ensure
    File.chmod(0o644, secret) if secret
  end

  # --- bin/syncbox как отдельный процесс -------------------------------------

  def test_bin_exits_1_on_a_partial_failure_and_on_an_unreachable_server
    start_server
    write("a.txt", "a")
    write(".syncbox-tmp/x", "x")
    out, err, status = run_bin("push", @dir, "--server", @server.url)
    assert_equal 1, status.exitstatus
    assert_includes out.lines(chomp: true), "push incomplete: 1 uploaded, 0 unchanged, 1 failed, 2 files total"
    assert_match(%r{^syncbox: push failed for 1 of 2 files:\n  \.syncbox-tmp/x: PUT /blobs/\.syncbox-tmp/x: server responded 400}, err)
    assert_equal ["a.txt"], @server.keys

    (out, err, status), seconds = timed { run_bin("sync", @dir, "--server", "http://127.0.0.1:#{free_port}") }
    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(/\Asyncbox: cannot connect to server http:\/\/127\.0\.0\.1:\d+: Connection refused/, err)
    assert_operator seconds, :<, 10
  end
end
