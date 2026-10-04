# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "support/server_process"

# Runs bin/syncbox as a separate process, the way run-client does inside the
# container, against a real server (bin/syncbox-server) over HTTP.
class ClientProcessTest < Minitest::Test
  include ServerProcess

  CLIENT_BIN = File.expand_path("../bin/syncbox", __dir__)

  def setup
    @tmp = Dir.mktmpdir
    @port = free_port
    @dir = File.join(@tmp, "local")
    Dir.mkdir(@dir)
  end

  def teardown
    stop_server
    FileUtils.rm_rf(@tmp)
  end

  def test_push_uploads_the_directory_byte_for_byte
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    files = {
      "a.txt" => "hello\n", "empty" => "", "docs/data.bin" => Random.new(7).bytes(1_000_000),
      "docs/deep/er/x" => "x", "with space/100% ✓ #1?.txt" => "odd name", "a\\b" => "backslash"
    }
    files.each { |key, content| write(key, content) }

    out, err, status = client("push", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "", err
    assert_equal files.keys.sort.map { |key| "uploaded #{key}\n" }.join + "push: 6 uploaded, 0 up to date\n", out
    assert_equal files.keys.sort, stored.keys
    files.each do |key, content|
      assert_equal Digest::SHA256.hexdigest(content), stored[key]["sha256"], key
      assert_equal content, get(Syncbox::Client::Remote.new(URI(url)).blob_path(key)).body.b, key
    end
  end

  def test_push_skips_unchanged_files_and_uploads_changed_ones
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("same", "same")
    write("edited", "before")
    write("dir/resized", "short")
    assert_predicate client("push", @dir, "--server", url)[2], :success?
    modified_at = stored.transform_values { |blob| blob["modified_at"] }

    write("edited", "after!") # same size, other content
    write("dir/resized", "much longer now")
    write("dir/new", "new")
    out, err, status = client("push", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "uploaded dir/new\nuploaded dir/resized\nuploaded edited\npush: 3 uploaded, 1 up to date\n", out
    assert_equal modified_at["same"], stored["same"]["modified_at"], "an unchanged file must not be uploaded again"
    assert_equal Digest::SHA256.hexdigest("after!"), stored["edited"]["sha256"]
    assert_equal Digest::SHA256.hexdigest("much longer now"), stored["dir/resized"]["sha256"]

    out, = client("push", @dir, "--server", url)

    assert_equal "push: 0 uploaded, 4 up to date\n", out
  end

  def test_push_leaves_blobs_without_a_local_file_alone
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    Net::HTTP.start("127.0.0.1", @port) { |http| http.put("/blobs/server-only", "kept") }
    write("local", "x")

    assert_predicate client("push", @dir, "--server", url)[2], :success?
    assert_equal %w[local server-only], stored.keys
  end

  def test_server_from_environment_and_base_url_with_trailing_slash
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("f", "x")

    out, err, status = client("push", @dir, env: { "SYNCBOX_SERVER" => "#{url}/" })

    assert_predicate status, :success?, err
    assert_equal "uploaded f\npush: 1 uploaded, 0 up to date\n", out
    assert_equal %w[f], stored.keys
  end

  def test_key_rejected_by_the_server_fails_that_file_alone
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("..\\escape", "x") # a valid local name, but a traversal key for the server
    write("ok", "y")

    out, err, status = client("push", @dir, "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "uploaded ok\npush: 1 uploaded, 0 up to date, 1 failed\n", out
    assert_match(/\Asyncbox: push incomplete: 1 failed:\n  cannot upload \.\.\\escape: server answered 400 invalid key\n\z/, err)
    assert_equal %w[ok], stored.keys
  end

  def test_unreachable_server_fails_fast_with_a_message
    write("f", "x")
    started = Time.now

    out, err, status = client("push", @dir, "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot list blobs: server #{Regexp.escape(url)} is unreachable: .*refused.*\n\z}, err)
    assert_operator Time.now - started, :<, 15
  end

  def test_missing_directory_fails
    out, err, status = client("push", File.join(@tmp, "missing"), "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_equal "syncbox: not a directory: #{File.join(@tmp, 'missing')}\n", err
  end

  def test_pull_downloads_what_push_uploaded_byte_for_byte
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    files = {
      "a.txt" => "hello\n", "empty" => "", "docs/data.bin" => Random.new(8).bytes(1_000_000),
      "docs/deep/er/x" => "x", "with space/100% ✓ #1?.txt" => "odd name", "a\\b" => "backslash"
    }
    files.each { |key, content| write(key, content) }
    assert_predicate client("push", @dir, "--server", url)[2], :success?
    other = File.join(@tmp, "other")
    Dir.mkdir(other)

    out, err, status = client("pull", other, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "", err
    assert_equal files.keys.sort.map { |key| "downloaded #{key}\n" }.join + "pull: 6 downloaded, 0 up to date\n", out
    assert_equal files.keys.sort, Dir.glob("**/*", base: other).select { |key| File.file?(File.join(other, key)) }.sort
    files.each do |key, content|
      assert_equal Digest::SHA256.hexdigest(content), Digest::SHA256.file(File.join(other, key)).hexdigest, key
    end
  end

  def test_pull_skips_unchanged_files_and_leaves_local_only_files_alone
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    { "same" => "same", "edited" => "after!", "dir/resized" => "much longer now", "dir/new" => "new" }.each do |key, content|
      Net::HTTP.start("127.0.0.1", @port) { |http| http.put(Syncbox::Client::Remote.new(URI(url)).blob_path(key), content) }
    end
    write("same", "same")
    write("edited", "before")
    write("dir/resized", "short")
    write("local-only", "kept")
    File.utime(Time.at(0), Time.at(0), File.join(@dir, "same"))

    out, err, status = client("pull", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "downloaded dir/new\ndownloaded dir/resized\ndownloaded edited\npull: 3 downloaded, 1 up to date\n", out
    assert_equal Time.at(0), File.mtime(File.join(@dir, "same")), "an unchanged file must not be downloaded again"
    assert_equal "after!", File.read(File.join(@dir, "edited"))
    assert_equal "much longer now", File.read(File.join(@dir, "dir/resized"))
    assert_equal "kept", File.read(File.join(@dir, "local-only"))
    assert_equal %w[dir edited local-only same], Dir.children(@dir).sort

    out, = client("pull", @dir, "--server", url)

    assert_equal "pull: 0 downloaded, 4 up to date\n", out
  end

  def test_pull_with_server_from_environment
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    Net::HTTP.start("127.0.0.1", @port) { |http| http.put("/blobs/f", "x") }

    out, err, status = client("pull", @dir, env: { "SYNCBOX_SERVER" => url })

    assert_predicate status, :success?, err
    assert_equal "downloaded f\npull: 1 downloaded, 0 up to date\n", out
    assert_equal "x", File.read(File.join(@dir, "f"))
  end

  def test_pull_from_an_unreachable_server_fails_fast_with_a_message
    started = Time.now

    out, err, status = client("pull", @dir, "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot list blobs: server #{Regexp.escape(url)} is unreachable: .*refused.*\n\z}, err)
    assert_operator Time.now - started, :<, 15
    assert_equal [], Dir.children(@dir)
  end

  def test_pull_into_a_missing_directory_fails
    out, err, status = client("pull", File.join(@tmp, "missing"), "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_equal "syncbox: not a directory: #{File.join(@tmp, 'missing')}\n", err
  end

  def test_status_reports_both_directions_and_changes_nothing
    data = File.join(@tmp, "data")
    start_server("--data-dir", data, "--port", @port.to_s)
    { "same" => "same", "edited" => "server", "server-only" => "r", "dir/server-only" => "r",
      "with space/✓ #1%?.txt" => "odd" }.each { |key, content| put(key, content) }
    write("same", "same")
    write("edited", "local!")
    write("local-only", "l")
    write("dir/deep/local-only", "l")
    File.utime(Time.at(0), Time.at(0), File.join(@dir, "same"))
    server_before = stored
    data_before = snapshot(data)
    local_before = snapshot(@dir)

    out, err, status = client("status", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "", err
    assert_equal <<~OUT, out
      upload (not on server): dir/deep/local-only
      upload (content differs): edited
      upload (not on server): local-only
      download (not local): dir/server-only
      download (content differs): edited
      download (not local): server-only
      download (not local): with space/✓ #1%?.txt
      status: 3 to upload, 4 to download, 1 up to date
    OUT
    assert_equal server_before, stored
    assert_equal data_before, snapshot(data)
    assert_equal local_before, snapshot(@dir)
  end

  def test_status_after_push_and_pull_has_nothing_to_do
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("a", "x")
    put("b/c", "y")
    assert_predicate client("push", @dir, "--server", url)[2], :success?
    assert_predicate client("pull", @dir, "--server", url)[2], :success?

    out, err, status = client("status", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "status: nothing to upload or download, 2 up to date\n", out
  end

  def test_status_with_server_from_environment
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    put("f", "x")

    out, err, status = client("status", @dir, env: { "SYNCBOX_SERVER" => url })

    assert_predicate status, :success?, err
    assert_equal "download (not local): f\nstatus: 0 to upload, 1 to download, 0 up to date\n", out
    assert_equal [], Dir.children(@dir)
  end

  def test_status_against_an_unreachable_server_fails_fast_with_a_message
    write("f", "x")
    started = Time.now

    out, err, status = client("status", @dir, "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot list blobs: server #{Regexp.escape(url)} is unreachable: .*refused.*\n\z}, err)
    assert_operator Time.now - started, :<, 15
  end

  def test_status_of_a_missing_directory_fails
    out, err, status = client("status", File.join(@tmp, "missing"), "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_equal "syncbox: not a directory: #{File.join(@tmp, 'missing')}\n", err
  end

  def test_sync_copies_one_sided_files_both_ways_byte_for_byte
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    local = { "a.txt" => "hello\n", "docs/data.bin" => Random.new(9).bytes(1_000_000), "with space/✓ #1%?.txt" => "odd" }
    server = { "empty" => "", "docs/deep/er/x" => Random.new(10).bytes(300_000), "a\\b" => "backslash" }
    local.each { |key, content| write(key, content) }
    server.each { |key, content| put(key, content) }

    out, err, status = client("sync", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "", err
    assert_equal <<~OUT, out
      uploaded a.txt
      downloaded a\\b
      uploaded docs/data.bin
      downloaded docs/deep/er/x
      downloaded empty
      uploaded with space/✓ #1%?.txt
      sync: 3 uploaded, 3 downloaded, 0 up to date
    OUT
    all = local.merge(server)
    assert_equal all.keys.sort, stored.keys
    assert_equal all.keys.sort, local_keys
    all.each do |key, content|
      assert_equal Digest::SHA256.hexdigest(content), stored[key]["sha256"], key
      assert_equal Digest::SHA256.hexdigest(content), Digest::SHA256.file(File.join(@dir, key)).hexdigest, key
    end

    out, err, status = client("sync", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "sync: 0 uploaded, 0 downloaded, 6 up to date\n", out
    # The sync state in the directory is the client's own: nothing to push.
    assert_equal "status: nothing to upload or download, 6 up to date\n", client("status", @dir, "--server", url)[0]
    assert_equal "push: 0 uploaded, 6 up to date\n", client("push", @dir, "--server", url)[0]
  end

  def test_sync_carries_one_sided_changes_and_resolves_conflicts_by_time
    data = File.join(@tmp, "data")
    start_server("--data-dir", data, "--port", @port.to_s)
    t0 = Time.utc(2026, 1, 1, 12)
    %w[local-edit server-edit local-newer server-newer same-time].each do |key|
      write(key, "v1", mtime: t0)
      put(key, "v1", mtime: t0, data: data)
    end
    assert_predicate client("sync", @dir, "--server", url)[2], :success?

    # Changed on one side only: the change wins whatever the times say.
    write("local-edit", "local v2", mtime: t0 - 3600)
    put("server-edit", "server v2", mtime: t0 - 3600, data: data)
    # Changed on both sides: the more recent copy wins, the local one on a tie.
    write("local-newer", "local v2", mtime: t0 + 20)
    put("local-newer", "server v2", mtime: t0 + 10, data: data)
    write("server-newer", "local v2", mtime: t0 + 10)
    put("server-newer", "server v2", mtime: t0 + 20, data: data)
    write("same-time", "local v2", mtime: t0 + Rational(1, 1000))
    put("same-time", "server v2", mtime: t0 + Rational(1, 1000), data: data)
    # New on one side only.
    write("local-only", "l")
    put("server-only", "s")

    out, err, status = client("sync", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "", err
    assert_equal <<~OUT, out
      uploaded local-edit
      uploaded local-newer (conflict: local copy is newer)
      uploaded local-only
      uploaded same-time (conflict: same modification time, local copy wins)
      downloaded server-edit
      downloaded server-newer (conflict: server copy is newer)
      downloaded server-only
      sync: 4 uploaded, 3 downloaded, 0 up to date
    OUT
    expected = { "local-edit" => "local v2", "server-edit" => "server v2", "local-newer" => "local v2",
                 "server-newer" => "server v2", "same-time" => "local v2", "local-only" => "l", "server-only" => "s" }
    expected.each do |key, content|
      assert_equal content, File.binread(File.join(@dir, key)), key
      assert_equal Digest::SHA256.hexdigest(content), stored[key]["sha256"], key
    end
  end

  def test_sync_deletes_nothing
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("local-deleted", "l")
    put("server-deleted", "s")
    assert_predicate client("sync", @dir, "--server", url)[2], :success?
    File.delete(File.join(@dir, "local-deleted"))
    Net::HTTP.start("127.0.0.1", @port) { |http| http.delete("/blobs/server-deleted") }

    out, err, status = client("sync", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "downloaded local-deleted\nuploaded server-deleted\nsync: 1 uploaded, 1 downloaded, 0 up to date\n", out
    assert_equal %w[local-deleted server-deleted], stored.keys
    assert_equal %w[local-deleted server-deleted], local_keys
  end

  def test_sync_with_server_from_environment
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    put("f", "x")
    write("g", "y")

    out, err, status = client("sync", @dir, env: { "SYNCBOX_SERVER" => "#{url}/" })

    assert_predicate status, :success?, err
    assert_equal "downloaded f\nuploaded g\nsync: 1 uploaded, 1 downloaded, 0 up to date\n", out
    assert_equal %w[f g], stored.keys
  end

  def test_sync_with_an_unreachable_server_fails_fast_and_changes_nothing
    write("f", "x")
    started = Time.now

    out, err, status = client("sync", @dir, "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot list blobs: server #{Regexp.escape(url)} is unreachable: .*refused.*\n\z}, err)
    assert_operator Time.now - started, :<, 15
    assert_equal %w[f], Dir.children(@dir)
  end

  def test_sync_of_a_missing_directory_fails
    out, err, status = client("sync", File.join(@tmp, "missing"), "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_equal "syncbox: not a directory: #{File.join(@tmp, 'missing')}\n", err
  end

  def test_usage_errors
    [["push", @dir], ["sync", @dir], ["push"], ["fetch", @dir, "--server", url],
     ["push", @dir, "--server", "nope"]].each do |argv|
      out, err, status = client(*argv)

      assert_equal 2, status.exitstatus, argv.inspect
      assert_equal "", out
      assert_match(/\Asyncbox: .*\nUsage: syncbox <push\|pull\|status\|sync> <dir> --server <url>\n\z/, err)
    end
  end

  def test_help
    out, _, status = client("--help")

    assert_predicate status, :success?
    assert_match(/\AUsage: syncbox/, out)
  end

  private

  def url
    "http://127.0.0.1:#{@port}"
  end

  def client(*args, env: {})
    Open3.capture3(clean_env.merge(env), CLIENT_BIN, *args)
  end

  def write(key, content, mtime: nil)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    File.utime(mtime, mtime, path) if mtime
  end

  # Uploads a blob; with +mtime+, also dates it (the server lists the mtime
  # of the blob file under +data+ as its modified_at).
  def put(key, content, mtime: nil, data: nil)
    Net::HTTP.start("127.0.0.1", @port) { |http| http.put(Syncbox::Client::Remote.new(URI(url)).blob_path(key), content) }
    File.utime(mtime, mtime, File.join(data, "blobs", key)) if mtime
  end

  # The keys of the user's regular files under the directory, without the
  # client's sync state.
  def local_keys
    Dir.glob("**/*", base: @dir).select { |key| File.file?(File.join(@dir, key)) }.sort
  end

  # Everything under +root+: {relative path => [type, mode, mtime, content]}.
  def snapshot(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |rel| File.basename(rel) == "." }.sort.to_h do |rel|
      stat = File.lstat(File.join(root, rel))
      [rel, [stat.ftype, stat.mode, stat.mtime, stat.file? ? File.binread(File.join(root, rel)) : nil]]
    end
  end

  # The server's blob list: {key => metadata}.
  def stored
    JSON.parse(get("/blobs").body).to_h { |blob| [blob["key"], blob] }
  end
end
