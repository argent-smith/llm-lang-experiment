# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "stringio"
require "time"

# Sync against a scripted stand-in for the API: checks the decision for every
# combination of local file, server blob and last known common version — in
# particular the spec's conflict rule — plus the state file, independent of
# HTTP.
class ClientSyncTest < Minitest::Test
  include TestHelpers

  Sync = Syncbox::Client::Sync
  SyncState = Syncbox::Client::SyncState
  Api = Syncbox::Client::Api
  LocalTree = Syncbox::Client::LocalTree
  Transfer = Syncbox::Client::Transfer

  SERVER = "http://sync.test:8080"
  T0 = Time.utc(2026, 3, 1, 12, 0, 0)

  # An in-memory server: +remote+ maps key => content (stored at T0) or
  # key => [content, modified_at]. PUT stores the body with modified_at =
  # +now+; a key listed in +fail_put+ makes PUT raise, as a dead server would.
  class FakeApi
    attr_reader :puts, :gets, :list_calls, :closed
    attr_accessor :now, :fail_put

    def initialize(remote = {}, now: T0)
      @remote = {}
      remote.each { |key, value| store(key, *value) }
      @now = now
      @fail_put = []
      @puts = []
      @gets = []
      @list_calls = 0
      @closed = false
    end

    def store(key, content, modified_at = T0)
      modified_at = modified_at.utc.iso8601(3) if modified_at.is_a?(Time)
      @remote[key] = [content, modified_at]
    end

    def delete(key)
      @remote.delete(key)
    end

    def content(key)
      @remote.fetch(key).first
    end

    def keys
      @remote.keys.sort
    end

    def list
      @list_calls += 1
      @remote.map do |key, (content, modified_at)|
        Api::RemoteBlob.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content),
                            modified_at: modified_at)
      end
    end

    def put(key, path)
      raise Api::Unreachable, "cannot reach server at #{SERVER}: connection reset (PUT #{key})" if @fail_put.include?(key)

      content = File.binread(path)
      @puts << [key, content]
      store(key, content, @now)
      Api::PutResult.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))
    end

    def get(key, path)
      @gets << key
      content = content(key)
      File.binwrite(path, content)
      Api::GetResult.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content))
    end

    def close
      @closed = true
    end
  end

  def run_sync(dir, api, server: SERVER)
    out = StringIO.new
    err = StringIO.new
    summary = Sync.new(dir: dir, api: api, server: server, out: out, err: err).call
    [summary, out.string, err.string]
  end

  def test_first_run_copies_one_sided_files_both_ways_and_records_the_common_state
    with_tmpdir do |dir|
      write(dir, "same.txt", "same")
      write(dir, "local-only.txt", "mine")
      write(dir, "a/deep/local.bin", "\x00\x01".b)
      api = FakeApi.new({ "same.txt" => "same", "server-only.txt" => "theirs", "b/deep/server.bin" => "\x02".b })

      summary, out, err = run_sync(dir, api)

      assert_equal [["a/deep/local.bin", "\x00\x01".b], ["local-only.txt", "mine"]], api.puts
      assert_equal ["b/deep/server.bin", "server-only.txt"], api.gets
      assert_equal 1, api.list_calls, "the listing is fetched once"
      assert_equal [2, 2, 1, 0], [summary.uploaded, summary.downloaded, summary.unchanged, summary.conflicts]
      assert_equal <<~OUT, out
        uploaded a/deep/local.bin (new, 2 bytes)
        downloaded b/deep/server.bin (new, 1 bytes)
        uploaded local-only.txt (new, 4 bytes)
        downloaded server-only.txt (new, 6 bytes)
        sync done: 2 uploaded, 2 downloaded, 1 unchanged, 0 conflict(s) resolved
      OUT
      assert_equal "", err
      assert api.closed

      assert_equal "\x02".b, File.binread(File.join(dir, "b/deep/server.bin"))
      assert_equal "theirs", File.read(File.join(dir, "server-only.txt"))
      assert_equal "mine", File.read(File.join(dir, "local-only.txt")), "local files are never removed"
      assert_equal ["a/deep/local.bin", "b/deep/server.bin", "local-only.txt", "same.txt", "server-only.txt"], api.keys

      state = JSON.parse(File.read(File.join(dir, ".syncbox/state.json")))
      assert_equal 1, state["version"]
      expected = api.keys.to_h { |k| [k, Digest::SHA256.hexdigest(api.content(k))] }
      assert_equal expected, state.dig("servers", SERVER, "files"), "every key in sync is recorded with its hash"
      assert_equal ["a/deep/local.bin", "b/deep/server.bin", "local-only.txt", "same.txt", "server-only.txt"],
                   LocalTree.scan(dir).map(&:key), "the state directory is not a file of the tree"
    end
  end

  def test_second_run_of_a_synced_tree_transfers_nothing
    with_tmpdir do |dir|
      write(dir, "a", "A")
      api = FakeApi.new({ "b" => "B" })
      run_sync(dir, api)
      state_before = File.read(File.join(dir, ".syncbox/state.json"))
      api.puts.clear
      api.gets.clear

      summary, out, = run_sync(dir, api)
      assert_equal [], api.puts
      assert_equal [], api.gets
      assert_equal "sync done: 0 uploaded, 0 downloaded, 2 unchanged, 0 conflict(s) resolved\n", out
      assert_equal [0, 0, 2, 0], [summary.uploaded, summary.downloaded, summary.unchanged, summary.conflicts]
      assert_equal state_before, File.read(File.join(dir, ".syncbox/state.json")), "an unchanged state is not rewritten"
    end
  end

  def test_file_changed_only_locally_is_uploaded_whatever_the_timestamps_say
    with_tmpdir do |dir|
      write(dir, "f.txt", "v1")
      api = FakeApi.new({ "f.txt" => ["v1", T0] })
      run_sync(dir, api)

      # Only the local side moves. The server's blob is unchanged but carries
      # a modified_at far in the future: with a known common version the
      # timestamps are irrelevant, this is not a conflict.
      write(dir, "f.txt", "v2 local")
      File.utime(T0, T0, File.join(dir, "f.txt"))
      api.store("f.txt", "v1", T0 + 36_000)

      summary, out, = run_sync(dir, api)
      assert_equal "uploaded f.txt (changed locally, 8 bytes)\n" \
                   "sync done: 1 uploaded, 0 downloaded, 0 unchanged, 0 conflict(s) resolved\n", out
      assert_equal 0, summary.conflicts
      assert_equal "v2 local", api.content("f.txt")
      assert_equal [], api.gets
      assert_equal "v2 local", File.read(File.join(dir, "f.txt"))
    end
  end

  def test_file_changed_only_on_the_server_is_downloaded_whatever_the_timestamps_say
    with_tmpdir do |dir|
      write(dir, "f.txt", "v1")
      api = FakeApi.new({ "f.txt" => ["v1", T0] })
      run_sync(dir, api)

      # Only the server side moves, and its modified_at is *older* than the
      # untouched local file's mtime: still a download, not a conflict.
      api.store("f.txt", "v2 server", T0 - 36_000)
      File.utime(T0, T0, File.join(dir, "f.txt"))

      summary, out, = run_sync(dir, api)
      assert_equal "downloaded f.txt (changed on server, 9 bytes)\n" \
                   "sync done: 0 uploaded, 1 downloaded, 0 unchanged, 0 conflict(s) resolved\n", out
      assert_equal 0, summary.conflicts
      assert_equal "v2 server", File.read(File.join(dir, "f.txt"))
      assert_equal [], api.puts
    end
  end

  def test_conflict_is_won_by_the_fresher_side
    with_tmpdir do |dir|
      write(dir, "server-newer.txt", "base")
      write(dir, "local-newer.txt", "base")
      api = FakeApi.new({ "server-newer.txt" => "base", "local-newer.txt" => "base" })
      run_sync(dir, api)

      # Both sides change both files; the server's version of one is a
      # second fresher than the local mtime, the other a second older.
      write(dir, "server-newer.txt", "local edit")
      File.utime(T0 + 10, T0 + 10, File.join(dir, "server-newer.txt"))
      api.store("server-newer.txt", "server edit", T0 + 11)
      write(dir, "local-newer.txt", "local edit")
      File.utime(T0 + 10, T0 + 10, File.join(dir, "local-newer.txt"))
      api.store("local-newer.txt", "server edit", T0 + 9)

      summary, out, = run_sync(dir, api)
      assert_equal <<~OUT, out
        uploaded local-newer.txt (conflict, local is newer, 10 bytes)
        downloaded server-newer.txt (conflict, server is newer, 11 bytes)
        sync done: 1 uploaded, 1 downloaded, 0 unchanged, 2 conflict(s) resolved
      OUT
      assert_equal 2, summary.conflicts
      assert_equal "server edit", File.read(File.join(dir, "server-newer.txt"))
      assert_equal "server edit", api.content("server-newer.txt"), "the losing local version is not uploaded"
      assert_equal "local edit", api.content("local-newer.txt")
      assert_equal "local edit", File.read(File.join(dir, "local-newer.txt")), "the losing server version is not downloaded"

      # Both files are in sync again, so the next run is a no-op.
      _, out, = run_sync(dir, api)
      assert_equal "sync done: 0 uploaded, 0 downloaded, 2 unchanged, 0 conflict(s) resolved\n", out
    end
  end

  def test_conflict_with_equal_timestamps_is_won_by_the_local_side
    with_tmpdir do |dir|
      write(dir, "f.txt", "base")
      api = FakeApi.new({ "f.txt" => "base" })
      run_sync(dir, api)

      instant = T0 + Rational(123, 1000)
      write(dir, "f.txt", "local edit")
      File.utime(instant, instant, File.join(dir, "f.txt"))
      api.store("f.txt", "server edit", instant)

      summary, out, = run_sync(dir, api)
      assert_equal "uploaded f.txt (conflict, same mtime, local wins, 10 bytes)\n" \
                   "sync done: 1 uploaded, 0 downloaded, 0 unchanged, 1 conflict(s) resolved\n", out
      assert_equal 1, summary.conflicts
      assert_equal "local edit", api.content("f.txt")
      assert_equal "local edit", File.read(File.join(dir, "f.txt"))
      assert_equal [], api.gets
    end
  end

  def test_sub_millisecond_local_mtime_beyond_the_servers_precision_still_counts_as_fresher
    with_tmpdir do |dir|
      write(dir, "f.txt", "base")
      api = FakeApi.new({ "f.txt" => "base" })
      run_sync(dir, api)

      # The server reports milliseconds; a local mtime 1µs later is fresher,
      # one 1µs earlier is older (the listing's instant is exact).
      write(dir, "f.txt", "local edit")
      File.utime(T0 + Rational(123_001, 1_000_000), T0 + Rational(123_001, 1_000_000), File.join(dir, "f.txt"))
      api.store("f.txt", "server edit", T0 + Rational(123, 1000))
      _, out, = run_sync(dir, api)
      assert_match(/\Auploaded f\.txt \(conflict, local is newer/, out)

      write(dir, "f.txt", "local edit 2")
      File.utime(T0 + Rational(122_999, 1_000_000), T0 + Rational(122_999, 1_000_000), File.join(dir, "f.txt"))
      api.store("f.txt", "server edit 2", T0 + Rational(123, 1000))
      _, out, = run_sync(dir, api)
      assert_match(/\Adownloaded f\.txt \(conflict, server is newer/, out)
      assert_equal "server edit 2", File.read(File.join(dir, "f.txt"))
    end
  end

  def test_differing_files_without_a_common_version_follow_the_same_rule_but_are_not_conflicts
    with_tmpdir do |dir|
      write(dir, "server-newer.txt", "local")
      File.utime(T0, T0, File.join(dir, "server-newer.txt"))
      write(dir, "local-newer.txt", "local")
      File.utime(T0, T0, File.join(dir, "local-newer.txt"))
      write(dir, "tie.txt", "local")
      File.utime(T0, T0, File.join(dir, "tie.txt"))
      api = FakeApi.new({ "server-newer.txt" => ["server", T0 + 1], "local-newer.txt" => ["server", T0 - 1],
                          "tie.txt" => ["server", T0] })

      summary, out, = run_sync(dir, api)
      assert_equal <<~OUT, out
        uploaded local-newer.txt (differs on both sides, local is newer, 5 bytes)
        downloaded server-newer.txt (differs on both sides, server is newer, 6 bytes)
        uploaded tie.txt (differs on both sides, same mtime, local wins, 5 bytes)
        sync done: 2 uploaded, 1 downloaded, 0 unchanged, 0 conflict(s) resolved
      OUT
      assert_equal 0, summary.conflicts, "without a common version nothing is known to have changed on both sides"
      assert_equal "server", File.read(File.join(dir, "server-newer.txt"))
      assert_equal "local", api.content("local-newer.txt")
      assert_equal "local", api.content("tie.txt")
    end
  end

  def test_deletions_are_not_propagated_in_either_direction
    with_tmpdir do |dir|
      write(dir, "gone-locally.txt", "L")
      write(dir, "gone-on-server.txt", "S")
      write(dir, "gone-everywhere.txt", "E")
      api = FakeApi.new
      run_sync(dir, api)

      File.delete(File.join(dir, "gone-locally.txt"))
      api.delete("gone-on-server.txt")
      File.delete(File.join(dir, "gone-everywhere.txt"))
      api.delete("gone-everywhere.txt")

      summary, out, = run_sync(dir, api)
      assert_equal <<~OUT, out
        downloaded gone-locally.txt (missing locally, 1 bytes)
        uploaded gone-on-server.txt (missing on server, 1 bytes)
        sync done: 1 uploaded, 1 downloaded, 0 unchanged, 0 conflict(s) resolved
      OUT
      assert_equal 0, summary.conflicts
      assert_equal "L", File.read(File.join(dir, "gone-locally.txt")), "a file deleted locally comes back from the server"
      assert_equal "S", api.content("gone-on-server.txt"), "a blob deleted on the server comes back from the local copy"
      refute File.exist?(File.join(dir, "gone-everywhere.txt")), "nothing is invented for a key gone from both sides"
      assert_equal ["gone-locally.txt", "gone-on-server.txt"], api.keys

      state = SyncState.load(dir, server: SERVER)
      assert_equal ["gone-locally.txt", "gone-on-server.txt"], state.keys.sort,
                   "a key gone from both sides is dropped from the common state"
    end
  end

  def test_common_state_is_kept_per_server
    with_tmpdir do |dir|
      write(dir, "f.txt", "v1")
      run_sync(dir, FakeApi.new, server: "http://a.test")

      # Server B has never seen the directory: everything is new for it, and
      # syncing with it must not disturb what is known about server A.
      other = FakeApi.new
      _, out, = run_sync(dir, other, server: "http://b.test")
      assert_equal "uploaded f.txt (new, 2 bytes)\nsync done: 1 uploaded, 0 downloaded, 0 unchanged, 0 conflict(s) resolved\n", out

      state = JSON.parse(File.read(File.join(dir, ".syncbox/state.json")))
      assert_equal ["http://a.test", "http://b.test"], state["servers"].keys.sort
      assert_equal({ "f.txt" => Digest::SHA256.hexdigest("v1") }, state.dig("servers", "http://a.test", "files"))
      assert_equal({ "f.txt" => Digest::SHA256.hexdigest("v1") }, state.dig("servers", "http://b.test", "files"))
    end
  end

  def test_state_of_the_keys_already_reconciled_is_saved_when_a_later_transfer_fails
    with_tmpdir do |dir|
      write(dir, "a.txt", "A")
      write(dir, "b.txt", "B")
      write(dir, "c.txt", "C")
      api = FakeApi.new
      api.fail_put = ["b.txt"]

      out = StringIO.new
      error = assert_raises(Api::Unreachable) { Sync.new(dir: dir, api: api, server: SERVER, out: out, err: StringIO.new).call }
      assert_match(/cannot reach server/, error.message)
      assert_equal "uploaded a.txt (new, 1 bytes)\n", out.string, "the run stops at the first failure"
      assert_equal ["a.txt"], api.keys
      assert api.closed

      state = SyncState.load(dir, server: SERVER)
      assert_equal ["a.txt"], state.keys, "what was reconciled before the failure is remembered"

      # The rerun picks up where the failed run stopped.
      api.fail_put = []
      _, out, = run_sync(dir, api)
      assert_equal <<~OUT, out
        uploaded b.txt (new, 1 bytes)
        uploaded c.txt (new, 1 bytes)
        sync done: 2 uploaded, 0 downloaded, 1 unchanged, 0 conflict(s) resolved
      OUT
    end
  end

  def test_sha_mismatch_on_download_leaves_the_local_file_intact
    with_tmpdir do |dir|
      api = FakeApi.new({ "f.txt" => "listed" })
      api.define_singleton_method(:get) do |key, path|
        File.binwrite(path, "actually served")
        Api::GetResult.new(key: key, size: 15, sha256: Digest::SHA256.hexdigest("actually served"))
      end
      error = assert_raises(Transfer::Error) { run_sync(dir, api) }
      assert_match(/\Af\.txt: downloaded sha256 .* from the listing/, error.message)
      assert_equal [], Dir.children(dir), "no file, no staging file and — nothing was reconciled — no state is written"
    end
  end

  def test_unparseable_modified_at_is_an_error_only_when_a_conflict_needs_it
    with_tmpdir do |dir|
      write(dir, "same.txt", "same")
      write(dir, "local-only.txt", "x")
      api = FakeApi.new({ "same.txt" => ["same", "not a timestamp"] })
      _, out, = run_sync(dir, api)
      assert_match(/sync done: 1 uploaded, 0 downloaded, 1 unchanged/, out)

      write(dir, "same.txt", "local edit")
      api.store("same.txt", "server edit", "not a timestamp")
      error = assert_raises(Sync::Error) { run_sync(dir, api) }
      assert_equal "same.txt: cannot resolve the conflict: the server's modified_at \"not a timestamp\" " \
                   "is not an ISO 8601 timestamp", error.message
      assert_equal "local edit", File.read(File.join(dir, "same.txt"))
      assert_equal "server edit", api.content("same.txt")
    end
  end

  def test_server_keys_under_the_reserved_state_directory_are_refused
    with_tmpdir do |dir|
      api = FakeApi.new({ ".syncbox/state.json" => "{}" })
      error = assert_raises(LocalTree::Error) { run_sync(dir, api) }
      assert_equal "refusing key \".syncbox/state.json\" from the server: .syncbox is reserved for syncbox's own state",
                   error.message
      assert_equal [], api.gets
      assert_equal [], Dir.children(dir)
    end
  end

  def test_corrupt_state_file_is_reported_before_anything_is_transferred
    with_tmpdir do |dir|
      write(dir, ".syncbox/state.json", "{not json")
      write(dir, "f.txt", "f")
      api = FakeApi.new
      error = assert_raises(SyncState::Error) { run_sync(dir, api) }
      assert_match(%r{\A#{Regexp.escape(File.join(dir, '.syncbox/state.json'))}: not valid JSON .*delete the file}, error.message)
      assert_equal 0, api.list_calls
      assert_equal [], api.puts
      assert api.closed
    end
  end

  def test_missing_directory_is_an_error_before_the_listing_is_fetched
    with_tmpdir do |dir|
      api = FakeApi.new({ "f" => "x" })
      error = assert_raises(LocalTree::Error) { run_sync(File.join(dir, "nope"), api) }
      assert_match(/not a directory: .*nope/, error.message)
      assert_equal 0, api.list_calls
      assert api.closed
    end
  end

  private

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
