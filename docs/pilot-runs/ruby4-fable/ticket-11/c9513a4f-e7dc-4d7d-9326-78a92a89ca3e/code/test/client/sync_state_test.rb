# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"

# The sync state file: load/record/forget/save round trips, atomic writes,
# per-server entries and the refusal of unreadable files.
class ClientSyncStateTest < Minitest::Test
  include TestHelpers

  SyncState = Syncbox::Client::SyncState

  SHA_A = "a" * 64
  SHA_B = "b" * 64
  SERVER = "http://127.0.0.1:8080"

  def test_missing_file_is_an_empty_state_and_saving_it_writes_nothing
    with_tmpdir do |dir|
      state = SyncState.load(dir, server: SERVER)
      assert_equal File.join(dir, ".syncbox/state.json"), state.path
      assert state.empty?
      assert_nil state["x"]
      refute state.dirty?
      assert_nil state.save
      assert_equal [], Dir.children(dir), "nothing is created for a state with nothing to say"
    end
  end

  def test_record_save_and_load_round_trip_with_sorted_keys
    with_tmpdir do |dir|
      state = SyncState.load(dir, server: SERVER)
      state.record("z.txt", SHA_A)
      state.record("a/b.txt", SHA_B)
      assert state.dirty?
      assert_equal state.path, state.save
      refute state.dirty?

      document = JSON.parse(File.read(state.path))
      assert_equal({ "version" => 1, "servers" => { SERVER => { "files" => { "a/b.txt" => SHA_B, "z.txt" => SHA_A } } } },
                   document)
      assert_equal ["a/b.txt", "z.txt"], document["servers"][SERVER]["files"].keys, "keys are written sorted"
      assert_equal ["state.json"], Dir.children(File.join(dir, ".syncbox")), "no staging file is left behind"

      reloaded = SyncState.load(dir, server: SERVER)
      assert_equal SHA_A, reloaded["z.txt"]
      assert_equal SHA_B, reloaded["a/b.txt"]
      assert reloaded.key?("z.txt")
      refute reloaded.key?("missing")
      assert_equal ["z.txt", "a/b.txt"].sort, reloaded.keys.sort

      reloaded.record("z.txt", SHA_A)
      refute reloaded.dirty?, "recording the known value changes nothing"
      reloaded.forget("missing")
      refute reloaded.dirty?
      reloaded.forget("z.txt")
      assert reloaded.dirty?
      reloaded.save
      assert_equal({ "a/b.txt" => SHA_B }, JSON.parse(File.read(state.path)).dig("servers", SERVER, "files"))
    end
  end

  def test_entries_of_other_servers_are_preserved_as_read
    with_tmpdir do |dir|
      first = SyncState.load(dir, server: "http://a")
      first.record("f", SHA_A)
      first.save

      second = SyncState.load(dir, server: "http://b")
      assert second.empty?, "another server's state is not this server's"
      second.record("g", SHA_B)
      second.save

      document = JSON.parse(File.read(second.path))
      assert_equal({ "f" => SHA_A }, document.dig("servers", "http://a", "files"))
      assert_equal({ "g" => SHA_B }, document.dig("servers", "http://b", "files"))
    end
  end

  def test_unreadable_or_malformed_files_are_errors_that_name_the_file
    with_tmpdir do |dir|
      path = File.join(dir, ".syncbox/state.json")
      FileUtils.mkdir_p(File.dirname(path))

      {
        "{oops" => /not valid JSON/,
        "[]" => /expected a JSON object/,
        JSON.generate("version" => 2, "servers" => {}) => /unsupported sync state version 2 \(this client writes version 1\)/,
        JSON.generate("servers" => {}) => /unsupported sync state version nil/,
        JSON.generate("version" => 1, "servers" => []) => /"servers" must be an object/,
        JSON.generate("version" => 1, "servers" => { SERVER => { "files" => { "f" => "nope" } } }) => /malformed entry for server/,
        JSON.generate("version" => 1, "servers" => { SERVER => { "files" => [] } }) => /malformed entry for server/
      }.each do |content, pattern|
        File.write(path, content)
        error = assert_raises(SyncState::Error, content) { SyncState.load(dir, server: SERVER) }
        assert_match(/\A#{Regexp.escape(path)}: /, error.message)
        assert_match(pattern, error.message)
        assert_match(/delete the file to reset the sync state/, error.message)
      end

      # A file where the state directory should be.
      FileUtils.rm_rf(File.join(dir, ".syncbox"))
      File.write(File.join(dir, ".syncbox"), "x")
      error = assert_raises(SyncState::Error) { SyncState.load(dir, server: SERVER) }
      assert_match(/\Acannot read sync state .*state\.json: /, error.message)

      state = SyncState.new(path, SERVER, { "version" => 1, "servers" => {} }, {})
      state.record("f", SHA_A)
      error = assert_raises(SyncState::Error) { state.save }
      assert_match(/\Acannot write sync state .*state\.json: /, error.message)
      assert state.dirty?, "a failed save leaves the state dirty"
    end
  end

  def test_save_replaces_the_file_atomically_and_keeps_unknown_servers
    with_tmpdir do |dir|
      path = File.join(dir, ".syncbox/state.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate("version" => 1, "servers" => { "http://other" => { "files" => { "o" => SHA_B } } }))
      inode_before = File.stat(path).ino

      state = SyncState.load(dir, server: SERVER)
      state.record("f", SHA_A)
      state.save

      refute_equal inode_before, File.stat(path).ino, "the file is replaced by rename, not rewritten in place"
      assert_equal ["state.json"], Dir.children(File.join(dir, ".syncbox"))
      document = JSON.parse(File.read(path))
      assert_equal({ "o" => SHA_B }, document.dig("servers", "http://other", "files"))
      assert_equal({ "f" => SHA_A }, document.dig("servers", SERVER, "files"))
    end
  end
end
