# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "stringio"

# syncbox sync against the real server app over HTTP.
class ClientSyncTest < Minitest::Test
  STATE_FILE = ".syncbox-state.json"

  def setup
    @tmp = Dir.mktmpdir
    @dir = File.join(@tmp, "local")
    @data_dir = File.join(@tmp, "data")
    Dir.mkdir(@dir)
    @requests = []
    @server = serve(@data_dir, @requests)
  end

  def teardown
    @server.stop
    FileUtils.chmod_R("u+rwx", @tmp)
    FileUtils.remove_entry(@tmp)
  end

  # Files only on one side

  def test_local_only_files_are_uploaded
    files = { "top.txt" => "top", "docs/readme.txt" => "read me", "a/b/c/deep" => "deep", "empty" => "",
              "é/ü ñ.txt" => "unicode", "odd/50% #?+&=;.txt" => "needs escaping" }
    files.each { |key, body| write_local(key, body) }

    status, out, err = sync
    assert_equal 0, status, err
    assert_empty err
    assert_equal files.sort.to_h, server_files
    assert_equal files.keys.sort.map { |key| "uploaded #{key}\n" }.join +
                 "sync: 6 uploaded, 0 downloaded, 0 unchanged, 0 conflicts\n", out
  end

  def test_server_only_blobs_are_downloaded_creating_directories
    blobs = { "top.txt" => "top", "docs/img/logo.png" => "\x89PNG\x00\xFF".b, "a/b/c/deep" => "deep", "empty" => "" }
    blobs.each { |key, body| put_on_server(key, body) }

    status, out, err = sync
    assert_equal 0, status, err
    assert_empty err
    assert_equal blobs.sort.to_h, local_files
    assert_equal blobs.keys.sort.map { |key| "downloaded #{key}\n" }.join +
                 "sync: 0 uploaded, 4 downloaded, 0 unchanged, 0 conflicts\n", out
  end

  def test_one_pass_uploads_downloads_and_leaves_identical_files_alone
    write_local("same.txt", "same")
    put_on_server("same.txt", "same")
    write_local("mine/local.txt", "l")
    put_on_server("theirs/remote.txt", "r")

    status, out, = sync
    assert_equal 0, status
    assert_equal ["GET /blobs", "PUT /blobs/mine/local.txt", "GET /blobs/theirs/remote.txt"], @requests
    assert_equal "uploaded mine/local.txt\ndownloaded theirs/remote.txt\n" \
                 "sync: 1 uploaded, 1 downloaded, 1 unchanged, 0 conflicts\n", out
    expected = { "mine/local.txt" => "l", "same.txt" => "same", "theirs/remote.txt" => "r" }
    assert_equal expected, local_files
    assert_equal expected, server_files
  end

  def test_second_sync_transfers_nothing
    write_local("a", "a")
    put_on_server("dir/b", "b")
    assert_equal 0, sync.first
    state_mtime = File.mtime(state_path)

    @requests.clear
    status, out, = sync
    assert_equal 0, status
    assert_equal ["GET /blobs"], @requests
    assert_equal "sync: 0 uploaded, 0 downloaded, 2 unchanged, 0 conflicts\n", out
    assert_equal state_mtime, File.mtime(state_path), "an unchanged state is not rewritten"
  end

  # Files changed on one side since the last sync: the change is carried over,
  # whatever the modification times say.

  def test_file_changed_only_locally_is_uploaded
    synced("f.txt" => "v1", "other" => "o")
    path = write_local("f.txt", "local v2")
    File.utime(Time.at(946_684_800), Time.at(946_684_800), path) # older than the server's copy

    status, out, = sync
    assert_equal 0, status
    assert_equal "uploaded f.txt\nsync: 1 uploaded, 0 downloaded, 1 unchanged, 0 conflicts\n", out
    assert_equal({ "f.txt" => "local v2", "other" => "o" }, server_files)
    assert_equal({ "f.txt" => "local v2", "other" => "o" }, local_files)
  end

  def test_file_changed_only_on_the_server_is_downloaded
    synced("f.txt" => "v1", "other" => "o")
    put_on_server("f.txt", "server v2")
    set_server_mtime("f.txt", Time.at(946_684_800))
    local = File.join(@dir, "f.txt")
    File.utime(Time.now + 3600, Time.now + 3600, local) # newer than the server's copy

    status, out, = sync
    assert_equal 0, status
    assert_equal "downloaded f.txt\nsync: 0 uploaded, 1 downloaded, 1 unchanged, 0 conflicts\n", out
    assert_equal({ "f.txt" => "server v2", "other" => "o" }, local_files)
    assert_equal({ "f.txt" => "server v2", "other" => "o" }, server_files)
  end

  def test_changes_on_both_sides_to_different_files_are_both_carried_over
    synced("a" => "a1", "b" => "b1")
    write_local("a", "a2 local")
    put_on_server("b", "b2 server")

    status, out, = sync
    assert_equal 0, status
    assert_equal "uploaded a\ndownloaded b\nsync: 1 uploaded, 1 downloaded, 0 unchanged, 0 conflicts\n", out
    assert_equal({ "a" => "a2 local", "b" => "b2 server" }, local_files)
    assert_equal({ "a" => "a2 local", "b" => "b2 server" }, server_files)
  end

  # Conflicts: changed on both sides since the last sync.

  def test_conflict_newer_local_copy_wins
    synced("f.txt" => "v1")
    put_on_server("f.txt", "server v2")
    set_server_mtime("f.txt", Time.at(1_800_000_000))
    set_local("f.txt", "local v2", mtime: Time.at(1_800_000_001))

    status, out, = sync
    assert_equal 0, status
    assert_equal "conflict f.txt: changed on both sides since the last sync; the local copy is newer\n" \
                 "uploaded f.txt\nsync: 1 uploaded, 0 downloaded, 0 unchanged, 1 conflict\n", out
    assert_equal({ "f.txt" => "local v2" }, server_files)
    assert_equal({ "f.txt" => "local v2" }, local_files)
  end

  def test_conflict_newer_server_copy_wins
    synced("f.txt" => "v1")
    put_on_server("f.txt", "server v2")
    set_server_mtime("f.txt", Time.at(1_800_000_001))
    set_local("f.txt", "local v2", mtime: Time.at(1_800_000_000))

    status, out, = sync
    assert_equal 0, status
    assert_equal "conflict f.txt: changed on both sides since the last sync; the server's copy is newer\n" \
                 "downloaded f.txt\nsync: 0 uploaded, 1 downloaded, 0 unchanged, 1 conflict\n", out
    assert_equal({ "f.txt" => "server v2" }, local_files)
    assert_equal({ "f.txt" => "server v2" }, server_files)
  end

  def test_conflict_with_equal_mtime_local_copy_wins
    synced("f.txt" => "v1")
    put_on_server("f.txt", "server v2")
    time = Time.at(1_800_000_000, 123_456, :usec)
    set_server_mtime("f.txt", time)
    set_local("f.txt", "local v2", mtime: time)
    assert_equal time, Time.iso8601(server_listing.fetch("f.txt")["modified_at"])

    status, out, = sync
    assert_equal 0, status
    assert_equal "conflict f.txt: changed on both sides since the last sync; " \
                 "both were modified at the same time, keeping the local copy\n" \
                 "uploaded f.txt\nsync: 1 uploaded, 0 downloaded, 0 unchanged, 1 conflict\n", out
    assert_equal({ "f.txt" => "local v2" }, server_files)
    assert_equal({ "f.txt" => "local v2" }, local_files)
  end

  # The server reports microseconds; nanoseconds it can't show don't make the
  # local copy newer.
  def test_mtimes_are_compared_at_the_servers_precision
    synced("f.txt" => "v1")
    put_on_server("f.txt", "server v2")
    set_server_mtime("f.txt", Time.at(1_800_000_000, 123_456_000, :nsec))
    set_local("f.txt", "local v2", mtime: Time.at(1_800_000_000, 123_456_789, :nsec))

    status, out, = sync
    assert_equal 0, status
    assert_includes out, "both were modified at the same time, keeping the local copy\nuploaded f.txt\n"
    assert_equal({ "f.txt" => "local v2" }, server_files)
  end

  def test_mtimes_with_the_same_contents_are_irrelevant
    synced("f.txt" => "v1")
    put_on_server("f.txt", "same v2")
    set_local("f.txt", "same v2", mtime: Time.at(946_684_800))

    status, out, = sync
    assert_equal 0, status
    assert_equal "sync: 0 uploaded, 0 downloaded, 1 unchanged, 0 conflicts\n", out
  end

  # With no common state yet, a file that differs on both sides can't be
  # told changed on one side only, so the same rule decides.
  def test_first_sync_of_a_file_that_differs_on_both_sides_follows_the_conflict_rule
    put_on_server("old-local", "server")
    set_server_mtime("old-local", Time.at(1_800_000_001))
    set_local("old-local", "local", mtime: Time.at(1_800_000_000))
    put_on_server("new-local", "server")
    set_server_mtime("new-local", Time.at(1_800_000_000))
    set_local("new-local", "local", mtime: Time.at(1_800_000_001))
    put_on_server("tie", "server")
    set_server_mtime("tie", Time.at(1_800_000_000))
    set_local("tie", "local", mtime: Time.at(1_800_000_000))

    status, out, = sync
    assert_equal 0, status
    assert_equal "conflict new-local: differs on both sides, never synced; the local copy is newer\n" \
                 "uploaded new-local\n" \
                 "conflict old-local: differs on both sides, never synced; the server's copy is newer\n" \
                 "downloaded old-local\n" \
                 "conflict tie: differs on both sides, never synced; " \
                 "both were modified at the same time, keeping the local copy\n" \
                 "uploaded tie\nsync: 2 uploaded, 1 downloaded, 0 unchanged, 3 conflicts\n", out
    expected = { "new-local" => "local", "old-local" => "server", "tie" => "local" }
    assert_equal expected, local_files
    assert_equal expected, server_files
  end

  # Two directories synced through one server.

  def test_two_directories_converge_through_the_server
    other = File.join(@tmp, "other")
    Dir.mkdir(other)
    write_local("shared.txt", "v1")
    assert_equal 0, sync.first
    assert_equal 0, sync(dir: other).first
    assert_equal "v1", File.read(File.join(other, "shared.txt"))

    File.write(File.join(other, "shared.txt"), "v2 from other")
    File.write(File.join(other, "new.txt"), "new")
    assert_equal 0, sync(dir: other).first
    status, out, = sync
    assert_equal 0, status
    assert_equal "downloaded new.txt\ndownloaded shared.txt\n" \
                 "sync: 0 uploaded, 2 downloaded, 0 unchanged, 0 conflicts\n", out
    assert_equal({ "new.txt" => "new", "shared.txt" => "v2 from other" }, local_files)
  end

  # Deletions are not synced: what is missing on one side is copied back.

  def test_nothing_is_ever_deleted
    synced("deleted-locally" => "l", "deleted-on-server" => "s", "kept" => "k")
    File.delete(File.join(@dir, "deleted-locally"))
    delete_on_server("deleted-on-server")

    status, out, = sync
    assert_equal 0, status
    assert_equal "downloaded deleted-locally\nuploaded deleted-on-server\n" \
                 "sync: 1 uploaded, 1 downloaded, 1 unchanged, 0 conflicts\n", out
    expected = { "deleted-locally" => "l", "deleted-on-server" => "s", "kept" => "k" }
    assert_equal expected, local_files
    assert_equal expected, server_files
  end

  # The state file

  def test_state_records_what_both_sides_have_per_server
    synced("a" => "a", "dir/b" => "b")
    state = JSON.parse(File.read(state_path))
    assert_equal({ "version" => 1, "servers" => { "http://127.0.0.1:#{@server.port}" =>
      { "a" => Digest::SHA256.hexdigest("a"), "dir/b" => Digest::SHA256.hexdigest("b") } } }, state)
  end

  def test_nothing_to_sync_writes_no_state_file
    status, out, = sync
    assert_equal 0, status
    assert_equal "sync: 0 uploaded, 0 downloaded, 0 unchanged, 0 conflicts\n", out
    assert_empty Dir.children(@dir)
  end

  def test_state_file_is_never_content
    write_local("sub/#{STATE_FILE}", "a nested directory's state")
    synced("a" => "a")
    assert File.file?(state_path)
    assert_equal ["a"], server_files.keys

    assert_equal "push: 0 uploaded, 1 unchanged\n", run_cli("push", @dir)[1]
    assert_equal "status: in sync, 1 unchanged\n", run_cli("status", @dir)[1]

    put_on_server(STATE_FILE, "evil")
    put_on_server("sub/#{STATE_FILE}", "evil")
    put_on_server("x/#{STATE_FILE}/inside", "evil")
    before = File.read(state_path)
    %w[sync pull].each do |command|
      status, _out, err = run_cli(command, @dir)
      assert_equal 0, status, err
      [STATE_FILE, "sub/#{STATE_FILE}", "x/#{STATE_FILE}/inside"].each do |key|
        assert_includes err, "syncbox: skipping #{key}: #{STATE_FILE} is reserved for sync state\n", command
      end
    end
    assert_equal before, File.read(state_path)
    assert_equal "a nested directory's state", File.read(File.join(@dir, "sub", STATE_FILE))
  end

  # A state recorded with one server says nothing about another one.
  def test_state_is_kept_per_server
    synced("f" => "mine")
    other_data = File.join(@tmp, "other-data")
    TestHTTPServer.open(Syncbox::Server::Runner.build_app(Syncbox::Server::Config.new(data_dir: other_data,
                                                                                         port: 8080))) do |other|
      Net::HTTP.new("127.0.0.1", other.port).put("/blobs/f", "theirs", "content-type" => "application/octet-stream")
      File.utime(Time.at(946_684_800), Time.at(946_684_800), File.join(other_data, "blobs", "f"))

      status, out, = sync(server: other.url)
      assert_equal 0, status
      assert_match(/^conflict f: differs on both sides, never synced; the local copy is newer$/, out)
      assert_equal "mine", File.binread(File.join(other_data, "blobs", "f"))
      assert_equal ["http://127.0.0.1:#{@server.port}", "http://127.0.0.1:#{other.port}"].sort,
                   JSON.parse(File.read(state_path))["servers"].keys.sort
    end
  end

  def test_same_server_written_differently_shares_the_state
    synced("f" => "v1")
    put_on_server("f", "server v2")
    File.utime(Time.now + 3600, Time.now + 3600, File.join(@dir, "f")) # unchanged, but newer
    status, out, = sync(server: "http://127.0.0.1:#{@server.port}/")
    assert_equal 0, status
    assert_equal "downloaded f\nsync: 0 uploaded, 1 downloaded, 0 unchanged, 0 conflicts\n", out
  end

  def test_unreadable_state_file_is_ignored_with_a_warning
    synced("f" => "v1")
    File.write(state_path, "{not json")
    put_on_server("f", "server v2")
    set_server_mtime("f", Time.at(1_800_000_000))
    set_local("f", "local v2", mtime: Time.at(1_800_000_001))

    status, out, err = sync
    assert_equal 0, status
    assert_equal "syncbox: ignoring sync state #{STATE_FILE}: invalid JSON\n", err
    assert_match(/^conflict f: differs on both sides, never synced; the local copy is newer$/, out)
    assert_equal Digest::SHA256.hexdigest("local v2"),
                 JSON.parse(File.read(state_path))["servers"].values.first["f"]
  end

  def test_what_was_synced_before_a_failure_is_recorded
    write_local("a", "a")
    write_local("b", "b")
    server_app = Syncbox::Server::Runner.build_app(Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080))
    failing = lambda do |env|
      if env["REQUEST_METHOD"] == "PUT" && env["PATH_INFO"] == "/blobs/b"
        [500, { "content-type" => "text/plain" }, ["disk on fire\n"]]
      else
        server_app.call(env)
      end
    end
    TestHTTPServer.open(failing) do |broken|
      status, out, err = sync(server: broken.url)
      assert_equal 1, status
      assert_equal "uploaded a\n", out
      assert_equal "syncbox: server answered PUT b with HTTP 500: disk on fire\n", err
      assert_equal({ "a" => Digest::SHA256.hexdigest("a") },
                   JSON.parse(File.read(state_path))["servers"].fetch("http://127.0.0.1:#{broken.port}"))
    end
  end

  # Failures

  def test_unreachable_server_fails_fast_with_a_message
    write_local("a", "a")
    port = @server.port
    @server.stop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, out, err = sync(server: "http://127.0.0.1:#{port}")
    assert_equal 1, status
    assert_match(%r{\Asyncbox: cannot reach server http://127\.0\.0\.1:#{port}: Connection refused\n\z}, err)
    assert_empty out
    assert_equal ["a"], Dir.children(@dir)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_missing_or_non_directory_dir_fails_without_contacting_the_server
    status, _out, err = sync(dir: File.join(@tmp, "nope"))
    assert_equal 1, status
    assert_match(/no such directory/, err)

    status, _out, err = sync(dir: write_local("file", "x"))
    assert_equal 1, status
    assert_match(/not a directory/, err)
    assert_empty @requests
  end

  def test_invalid_modified_at_in_a_conflict_fails_with_a_message
    write_local("f", "local")
    listing = JSON.generate([{ "key" => "f", "size" => 6, "sha256" => Digest::SHA256.hexdigest("server"),
                               "modified_at" => "yesterday" }])
    TestHTTPServer.open(->(_env) { [200, { "content-type" => "application/json" }, [listing]] }) do |odd|
      status, _out, err = sync(server: odd.url)
      assert_equal 1, status
      assert_equal "syncbox: unexpected response from server to GET /blobs: invalid modified_at for f\n", err
    end
    assert_equal({ "f" => "local" }, local_files)
  end

  def test_skips_what_push_and_pull_would_skip_with_a_warning
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    File.write(File.join(outside, "file"), "outside")
    File.symlink(outside, File.join(@dir, "dirlink"))
    File.symlink(File.join(outside, "file"), File.join(@dir, "filelink"))
    put_on_server("dirlink/file", "evil")
    put_on_server("filelink", "evil")
    put_on_server("ok", "ok")

    status, out, err = sync
    assert_equal 0, status, err
    assert_equal "downloaded ok\nsync: 0 uploaded, 1 downloaded, 0 unchanged, 0 conflicts\n", out
    assert_includes err, "syncbox: skipping dirlink/file: dirlink is a symbolic link\n"
    assert_includes err, "syncbox: skipping filelink: symbolic link\n"
    assert_equal ["file"], Dir.children(outside)
    assert_equal "outside", File.read(File.join(outside, "file"))
  end

  private

  def serve(data_dir, requests)
    server_app = Syncbox::Server::Runner.build_app(Syncbox::Server::Config.new(data_dir: data_dir, port: 8080))
    TestHTTPServer.new(lambda { |env|
      requests << "#{env['REQUEST_METHOD']} #{env['PATH_INFO']}"
      server_app.call(env)
    })
  end

  def sync(dir: @dir, server: @server.url)
    run_cli("sync", dir, server: server)
  end

  def run_cli(command, dir, server: @server.url)
    out = StringIO.new
    err = StringIO.new
    status = Syncbox::Client::CLI.run([command, dir, "--server", server], env: {}, out: out, err: err)
    [status, out.string, err.string]
  end

  # Puts files on both sides and syncs them, so that they have a common state.
  def synced(files)
    files.each { |key, body| write_local(key, body) }
    status, _out, err = sync
    assert_equal 0, status, err
    assert_equal files.sort.to_h, server_files
    @requests.clear
  end

  def state_path
    File.join(@dir, STATE_FILE)
  end

  def write_local(key, body)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    path
  end

  def set_local(key, body, mtime:)
    File.utime(mtime, mtime, write_local(key, body))
  end

  # Every regular file under the local dir except sync state: {key => contents}.
  def local_files
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).sort.filter_map do |rel|
      path = File.join(@dir, rel)
      next if File.basename(rel) == STATE_FILE

      [rel, File.binread(path)] if File.file?(path) && !File.symlink?(path)
    end.to_h
  end

  def server_listing
    JSON.parse(Net::HTTP.get(URI("#{@server.url}/blobs"))).to_h { |blob| [blob["key"], blob] }
  ensure
    @requests.clear
  end

  # Every blob on the server: {key => contents}.
  def server_files
    server_listing.keys.to_h { |key| [key, File.binread(File.join(@data_dir, "blobs", key))] }
  end

  def put_on_server(key, body)
    response = Net::HTTP.new("127.0.0.1", @server.port)
                        .put("/blobs/#{Syncbox::Client::Remote.escape_key(key)}", body,
                             "content-type" => "application/octet-stream")
    assert_equal "201", response.code, key
    @requests.clear
  end

  def delete_on_server(key)
    response = Net::HTTP.new("127.0.0.1", @server.port).delete("/blobs/#{key}")
    assert_equal "204", response.code, key
    @requests.clear
  end

  def set_server_mtime(key, time)
    File.utime(time, time, File.join(@data_dir, "blobs", key))
  end
end
