# frozen_string_literal: true

require "test_helper"

# Манифест последнего общего состояния sync: чтение, атомарная запись,
# отсутствие файла, повреждённый файл.
class ClientSyncStateTest < Minitest::Test
  SyncState = Syncbox::Client::SyncState

  def setup
    @dir = Dir.mktmpdir("syncbox-state")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def path
    File.join(@dir, ".syncbox", "state.json")
  end

  def test_missing_file_is_an_empty_state
    state = SyncState.load(@dir)
    assert_equal({}, state.to_h)
    assert_nil state["x"]
    assert_equal path, state.path
    refute File.exist?(File.join(@dir, ".syncbox")), "loading creates nothing"
  end

  def test_round_trip_is_sorted_and_versioned
    state = SyncState.load(@dir)
    assert state.replace("b.txt" => "b" * 64, "a/x.txt" => "a" * 64)
    state.save

    payload = JSON.parse(File.read(path))
    assert_equal 1, payload["version"]
    assert_equal ["a/x.txt", "b.txt"], payload["files"].keys
    assert_equal({ "sha256" => "a" * 64 }, payload["files"]["a/x.txt"])
    assert_equal({ "a/x.txt" => "a" * 64, "b.txt" => "b" * 64 }, SyncState.load(@dir).to_h)
    assert_equal ["state.json"], Dir.children(File.join(@dir, ".syncbox")), "no temp files are left behind"
  end

  def test_replace_reports_whether_anything_changed
    state = SyncState.load(@dir)
    assert state.replace("a" => "a" * 64)
    refute state.replace("a" => "a" * 64)
    assert state.replace({})
  end

  def test_corrupt_files_are_rejected_with_the_path
    FileUtils.mkdir_p(File.dirname(path))
    [
      "{not json",
      "[]",
      JSON.generate("version" => 2, "files" => {}),
      JSON.generate("version" => 1, "files" => []),
      JSON.generate("version" => 1, "files" => { "x" => { "sha256" => "nope" } }),
      JSON.generate("version" => 1, "files" => { "x" => "abc" })
    ].each do |raw|
      File.write(path, raw)
      error = assert_raises(Syncbox::Client::Error, raw) { SyncState.load(@dir) }
      assert_match(/\Async state #{Regexp.escape(path)} is corrupt \(.*\); delete it to start over\z/, error.message)
    end
  end

  def test_save_replaces_the_file_atomically_and_keeps_the_old_one_on_failure
    state = SyncState.load(@dir)
    state.replace("a" => "a" * 64)
    state.save
    FileUtils.mkdir_p(File.join(@dir, ".syncbox", "state.json.dir"))
    state.replace("a" => "b" * 64)
    state.save
    assert_equal({ "a" => "b" * 64 }, SyncState.load(@dir).to_h)
  end

  def test_unwritable_directory_is_a_client_error
    skip "root ignores directory permissions" if Process.uid.zero?
    File.chmod(0o500, @dir)
    state = SyncState.load(@dir)
    state.replace("a" => "a" * 64)
    error = assert_raises(Syncbox::Client::Error) { state.save }
    assert_match(/\Acannot write sync state .*: Permission denied/, error.message)
  ensure
    File.chmod(0o755, @dir)
  end
end

# Зарезервированное имя клиента: ровно `.syncbox` и всё под ним.
class ClientReservedKeyTest < Minitest::Test
  def test_reserved_keys
    assert Syncbox::Client.reserved_key?(".syncbox")
    assert Syncbox::Client.reserved_key?(".syncbox/state.json")
    assert Syncbox::Client.reserved_key?(".syncbox/a/b")
    refute Syncbox::Client.reserved_key?(".syncboxx")
    refute Syncbox::Client.reserved_key?(".syncbox-tmp/x")
    refute Syncbox::Client.reserved_key?("sub/.syncbox/state.json")
    refute Syncbox::Client.reserved_key?("state.json")
  end
end
