# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "stringio"

class SyncTest < Minitest::Test
  Blob = Syncbox::Client::Remote::Blob
  Sync = Syncbox::Client::Sync

  SERVER = "http://127.0.0.1:8080"
  T0 = Time.utc(2026, 1, 1, 12, 0, 0)

  # In-memory stand-in for Remote. Each blob has a modification time: the
  # time it was given, or the fake's clock (+now+) at the time of its upload.
  class FakeRemote
    attr_accessor :now
    # Transfers of the +fail_on+ keys fail; from the +unreachable_from+ key
    # on, the server is unreachable.
    attr_accessor :fail_on, :unreachable_from
    attr_reader :uploads, :downloads

    # +contents+: {key => content} or {key => [content, modified_at]}.
    def initialize(contents = {}, now: T0, gone: [])
      @now = now
      @blobs = contents.to_h do |key, value|
        content, modified_at = value
        [key, [content.b, modified_at || now]]
      end
      @gone = gone
      @fail_on = []
      @uploads = []
      @downloads = []
    end

    def list
      @blobs.to_h do |key, (content, modified_at)|
        [key, Blob.new(key: key, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content),
                       modified_at: modified_at.utc.iso8601(6))]
      end
    end

    def put(key, io)
      fail_if_told("upload", key)
      @uploads << key
      @blobs[key] = [io.read.b, @now]
      Digest::SHA256.hexdigest(@blobs[key][0])
    end

    def get(key)
      raise Syncbox::Client::Remote::NotFound, "cannot download #{key}: not found on the server" if @gone.include?(key)

      fail_if_told("download", key)
      @downloads << key
      @blobs.fetch(key)[0].bytes.each_slice(1000) { |slice| yield slice.pack("C*") }
    end

    def fail_if_told(action, key)
      raise Syncbox::Client::Error, "cannot #{action} #{key}: server answered 500" if @fail_on.include?(key)
      return unless @unreachable_from && key >= @unreachable_from

      raise Syncbox::Client::Remote::Unreachable, "cannot #{action} #{key}: server is unreachable"
    end

    # Changes a blob the way another client's upload would.
    def change(key, content, modified_at)
      @blobs[key] = [content.b, modified_at]
    end

    def delete(key)
      @blobs.delete(key)
    end

    def contents
      @blobs.transform_values(&:first)
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_local_only_files_are_uploaded
    write("a.txt", "a")
    write("docs/deep/b.bin", Random.new(1).bytes(100_000))
    remote = FakeRemote.new

    sync(remote)

    assert_equal local_files, remote.contents
    assert_equal "uploaded a.txt\nuploaded docs/deep/b.bin\nsync: 2 uploaded, 0 downloaded, 0 up to date\n", @out.string
    assert_equal "", @err.string
  end

  def test_server_only_blobs_are_downloaded_into_new_directories
    content = Random.new(2).bytes(100_000)
    remote = FakeRemote.new({ "a.txt" => "a", "docs/deep/b.bin" => content, "with space/✓ #1%?.txt" => "odd" })

    sync(remote)

    assert_equal({ "a.txt" => "a", "docs/deep/b.bin" => content, "with space/✓ #1%?.txt" => "odd" }, local_files)
    assert_equal "downloaded a.txt\ndownloaded docs/deep/b.bin\ndownloaded with space/✓ #1%?.txt\n" \
                 "sync: 0 uploaded, 3 downloaded, 0 up to date\n", @out.string
  end

  def test_both_directions_in_one_pass_and_nothing_to_do_afterwards
    write("same", "same")
    write("local-only", "l")
    remote = FakeRemote.new({ "same" => "same", "dir/server-only" => "s" })

    sync(remote)

    assert_equal "downloaded dir/server-only\nuploaded local-only\nsync: 1 uploaded, 1 downloaded, 1 up to date\n",
                 @out.string
    assert_equal({ "same" => "same", "local-only" => "l", "dir/server-only" => "s" }, local_files)
    assert_equal local_files, remote.contents

    out = sync(remote)

    assert_equal "sync: 0 uploaded, 0 downloaded, 3 up to date\n", out
    assert_equal %w[local-only], remote.uploads
    assert_equal %w[dir/server-only], remote.downloads
  end

  def test_file_changed_only_locally_is_uploaded_however_old_its_mtime
    write("notes.txt", "v1")
    remote = FakeRemote.new
    sync(remote)

    write("notes.txt", "local v2", mtime: T0 - 3600) # older than the blob, still the only change
    out = sync(remote)

    assert_equal "uploaded notes.txt\nsync: 1 uploaded, 0 downloaded, 0 up to date\n", out
    assert_equal({ "notes.txt" => "local v2" }, remote.contents)
    assert_equal({ "notes.txt" => "local v2" }, local_files)
  end

  def test_file_changed_only_on_the_server_is_downloaded_however_old_its_modified_at
    write("notes.txt", "v1", mtime: T0)
    remote = FakeRemote.new
    sync(remote)

    remote.change("notes.txt", "server v2", T0 - 3600)
    out = sync(remote)

    assert_equal "downloaded notes.txt\nsync: 0 uploaded, 1 downloaded, 0 up to date\n", out
    assert_equal({ "notes.txt" => "server v2" }, local_files)
    assert_equal({ "notes.txt" => "server v2" }, remote.contents)
  end

  def test_conflict_the_newer_local_copy_wins
    remote = synced_with("notes.txt" => "v1")

    remote.change("notes.txt", "server v2", T0 + 10)
    write("notes.txt", "local v2", mtime: T0 + 20)
    out = sync(remote)

    assert_equal "uploaded notes.txt (conflict: local copy is newer)\nsync: 1 uploaded, 0 downloaded, 0 up to date\n", out
    assert_equal({ "notes.txt" => "local v2" }, remote.contents)
    assert_equal({ "notes.txt" => "local v2" }, local_files)
  end

  def test_conflict_the_newer_server_copy_wins
    remote = synced_with("notes.txt" => "v1")

    write("notes.txt", "local v2", mtime: T0 + 10)
    remote.change("notes.txt", "server v2", T0 + 20)
    out = sync(remote)

    assert_equal "downloaded notes.txt (conflict: server copy is newer)\n" \
                 "sync: 0 uploaded, 1 downloaded, 0 up to date\n", out
    assert_equal({ "notes.txt" => "server v2" }, local_files)
    assert_equal({ "notes.txt" => "server v2" }, remote.contents)
  end

  def test_conflict_with_the_same_time_the_local_copy_wins
    remote = synced_with("notes.txt" => "v1")

    remote.change("notes.txt", "server v2", T0 + Rational(123_456, 1_000_000))
    write("notes.txt", "local v2", mtime: T0 + Rational(123_456, 1_000_000))
    out = sync(remote)

    assert_equal "uploaded notes.txt (conflict: same modification time, local copy wins)\n" \
                 "sync: 1 uploaded, 0 downloaded, 0 up to date\n", out
    assert_equal({ "notes.txt" => "local v2" }, remote.contents)
  end

  def test_mtime_is_compared_at_the_precision_of_modified_at
    remote = synced_with("a" => "v1", "b" => "v1")
    remote.change("a", "server v2", T0)
    remote.change("b", "server v2", T0)
    write("a", "local v2", mtime: T0 + Rational(4, 10))
    write("b", "local v2", mtime: T0 - Rational(4, 10))
    whole_seconds = remote.method(:list)
    remote.define_singleton_method(:list) do
      whole_seconds.call.transform_values { |blob| blob.with(modified_at: Time.iso8601(blob.modified_at).iso8601) }
    end

    out = sync(remote)

    # 12:00:00.4 is 12:00:00 to a server listing whole seconds; 11:59:59.6 is not.
    assert_equal "uploaded a (conflict: same modification time, local copy wins)\n" \
                 "downloaded b (conflict: server copy is newer)\n" \
                 "sync: 1 uploaded, 1 downloaded, 0 up to date\n", out
  end

  def test_differing_copies_without_a_common_version_go_by_mtime
    write("local-newer", "local", mtime: T0 + 1)
    write("server-newer", "local", mtime: T0 - 1)
    write("same-time", "local", mtime: T0)
    remote = FakeRemote.new({ "local-newer" => "server", "server-newer" => "server", "same-time" => "server" })

    out = sync(remote)

    assert_equal "uploaded local-newer (conflict: local copy is newer)\n" \
                 "uploaded same-time (conflict: same modification time, local copy wins)\n" \
                 "downloaded server-newer (conflict: server copy is newer)\n" \
                 "sync: 2 uploaded, 1 downloaded, 0 up to date\n", out
    assert_equal({ "local-newer" => "local", "same-time" => "local", "server-newer" => "server" }, remote.contents)
    assert_equal remote.contents, local_files
  end

  def test_nothing_is_deleted_on_either_side
    remote = synced_with("local-deleted" => "l", "server-deleted" => "s", "kept" => "k")
    File.delete(path("local-deleted"))
    remote.delete("server-deleted")

    out = sync(remote)

    assert_equal "downloaded local-deleted\nuploaded server-deleted\nsync: 1 uploaded, 1 downloaded, 1 up to date\n", out
    assert_equal({ "local-deleted" => "l", "server-deleted" => "s", "kept" => "k" }, local_files)
    assert_equal local_files, remote.contents
  end

  def test_state_directory_is_neither_uploaded_nor_downloaded_into
    remote = synced_with("a" => "a")
    remote.change(".syncbox/state.json", "evil", T0)
    remote.change(".syncbox", "evil", T0)
    state = File.binread(path(".syncbox/state.json"))

    out = sync(remote)

    assert_equal "sync: 0 uploaded, 0 downloaded, 1 up to date\n", out
    assert_equal ["syncbox: skipping .syncbox: .syncbox is reserved for the client's sync state",
                  "syncbox: skipping .syncbox/state.json: .syncbox is reserved for the client's sync state"],
                 @err.string.lines(chomp: true)
    assert_equal state, File.binread(path(".syncbox/state.json"))
    assert_equal %w[.syncbox .syncbox/state.json a], remote.contents.keys.sort
  end

  def test_state_is_kept_per_server
    remote = synced_with("notes.txt" => "v1")
    other = FakeRemote.new({ "notes.txt" => ["other", T0 - 3600] })

    # With this server notes.txt has no common version: both copies count as changed.
    out = sync(other, server: "http://other:8080")

    assert_equal "uploaded notes.txt (conflict: local copy is newer)\nsync: 1 uploaded, 0 downloaded, 0 up to date\n", out
    assert_equal({ "notes.txt" => "v1" }, other.contents)
    assert_equal %w[http://127.0.0.1:8080 http://other:8080], state["servers"].keys.sort
    assert_equal "sync: 0 uploaded, 0 downloaded, 1 up to date\n", sync(remote)
  end

  def test_state_records_what_both_sides_hold
    write("a", "a")
    write("b", "b")
    sync(FakeRemote.new({ "b" => "b", "c" => "c" }))

    assert_equal({ "version" => 1,
                   "servers" => { SERVER => { "a" => sha("a"), "b" => sha("b"), "c" => sha("c") } } }, state)
  end

  def test_skipped_entries_keep_their_common_version
    remote = synced_with("file" => "v1", "other" => "o")
    File.delete(path("file"))
    File.symlink("other", path("file"))
    remote.change("file", "server v2", T0 + 10)

    out = sync(remote)

    assert_equal "sync: 0 uploaded, 0 downloaded, 1 up to date\n", out
    assert_equal "syncbox: skipping file: symbolic link\n", @err.string
    assert_equal sha("v1"), state.dig("servers", SERVER, "file")
    assert_equal({ "file" => "server v2", "other" => "o" }, remote.contents)
  end

  def test_blob_deleted_from_the_server_meanwhile_is_skipped
    remote = FakeRemote.new({ "gone" => "g", "kept" => "k" }, gone: ["gone"])

    out = sync(remote)

    assert_equal "downloaded kept\nsync: 0 uploaded, 1 downloaded, 0 up to date\n", out
    assert_equal "syncbox: skipping gone: deleted from the server meanwhile\n", @err.string
    assert_equal({ "kept" => "k" }, local_files)
  end

  def test_obstacles_fail_alone
    write("local-only", "l")
    write("a", "file where a directory should be")
    remote = FakeRemote.new({ "a/b" => "x", "z" => "z" })

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { sync(remote) }

    assert_equal "sync incomplete: 1 failed", error.message
    assert_equal ["cannot write a/b: a is a file, not a directory"], error.failures
    assert_equal %w[a local-only], remote.uploads
    assert_equal %w[z], remote.downloads
    assert_equal "uploaded a\nuploaded local-only\ndownloaded z\nsync: 2 uploaded, 1 downloaded, 0 up to date, 1 failed\n",
                 @out.string
    assert_equal %w[a local-only z], state.dig("servers", SERVER).keys
  end

  def test_failed_transfers_do_not_stop_the_others_and_keep_their_common_version
    remote = synced_with({ "both" => "v1", "down" => "v1", "up" => "v1", "ok" => "v1" })
    @out = StringIO.new
    write("up", "local v2")
    write("both", "local v2", mtime: T0 + 20)
    remote.change("down", "server v2", T0 + 10)
    remote.change("both", "server v2", T0 + 10)
    write("new", "n")
    remote.fail_on = %w[both down]

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { sync(remote) }

    assert_equal "sync incomplete: 2 failed", error.message
    assert_equal ["cannot upload both: server answered 500", "cannot download down: server answered 500"], error.failures
    assert_equal "uploaded new\nuploaded up\nsync: 2 uploaded, 0 downloaded, 1 up to date, 2 failed\n", @out.string
    assert_equal "v1", File.read(path("down"))
    assert_equal({ "both" => sha("v1"), "down" => sha("v1"), "new" => sha("n"), "ok" => sha("v1"), "up" => sha("local v2") },
                 state.dig("servers", SERVER))

    # Once the server is fine again, the next sync finishes the job the same
    # way: "both" changed on both sides, "down" on the server only.
    remote.fail_on = []
    @out.truncate(0)
    @out.rewind
    sync(remote)

    assert_equal "uploaded both (conflict: local copy is newer)\ndownloaded down\nsync: 1 uploaded, 1 downloaded, 3 up to date\n",
                 @out.string
    assert_equal "server v2", File.read(path("down"))
    assert_equal "local v2", remote.contents["both"]
  end

  def test_unreachable_server_stops_the_transfers_and_keeps_what_was_done
    write("a", "a")
    write("b", "b")
    write("c", "c")
    remote = FakeRemote.new({ "d" => "d" })
    remote.unreachable_from = "b"

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { sync(remote) }

    assert_equal "sync incomplete: 1 failed, 2 not attempted (server unreachable)", error.message
    assert_equal ["cannot upload b: server is unreachable"], error.failures
    assert_equal %w[a], remote.uploads
    assert_equal [], remote.downloads
    assert_equal "uploaded a\nsync: 1 uploaded, 0 downloaded, 0 up to date, 1 failed, 2 not attempted\n", @out.string
    assert_equal({ "a" => sha("a") }, state.dig("servers", SERVER))
  end

  def test_keys_outside_the_directory_are_rejected_before_anything_is_transferred
    write("local-only", "l")
    remote = FakeRemote.new({ "ok" => "x", "../escape" => "evil" })

    error = assert_raises(Syncbox::Client::Error) { sync(remote) }

    assert_equal 'server listed a key that is not a path inside the directory: "../escape"', error.message
    assert_equal [], remote.uploads
    assert_equal [], remote.downloads
  end

  def test_invalid_modified_at_in_a_conflict_fails_that_file
    write("f", "local")
    write("g", "g")
    remote = FakeRemote.new({ "f" => "server" })
    listed = remote.method(:list)
    remote.define_singleton_method(:list) { listed.call.transform_values { |blob| blob.with(modified_at: "yesterday") } }

    error = assert_raises(Syncbox::Client::Failures::Incomplete) { sync(remote) }

    assert_equal ['server listed an invalid modified_at for f: "yesterday"'], error.failures
    assert_equal %w[g], remote.uploads
  end

  def test_corrupt_state_is_an_error
    ["not json", "[]", '{"version":2,"servers":{}}', '{"version":1,"servers":{"s":{"k":"nope"}}}'].each do |json|
      write(".syncbox/state.json", json)
      remote = FakeRemote.new({ "f" => "x" })

      error = assert_raises(Syncbox::Client::Error, json) { sync(remote) }

      assert_equal "sync state .syncbox/state.json is corrupt; remove it to start afresh", error.message
      assert_equal [], remote.downloads
    end
  end

  def test_state_directory_that_is_not_a_directory_is_an_error
    write(".syncbox", "mine")

    error = assert_raises(Syncbox::Client::Error) { sync(FakeRemote.new({ "f" => "x" })) }

    assert_equal "cannot keep sync state: .syncbox is not a directory", error.message
    assert_equal "mine", File.read(path(".syncbox"))
  end

  def test_nothing_to_do_writes_no_state
    sync(FakeRemote.new)

    assert_equal "sync: 0 uploaded, 0 downloaded, 0 up to date\n", @out.string
    assert_equal [], Dir.children(@dir)
  end

  def test_directory_must_exist
    file = path("file")
    File.write(file, "")

    [path("missing"), file].each do |dir|
      error = assert_raises(Syncbox::Client::Error) { Sync.new(dir, FakeRemote.new, server: SERVER, out: @out, err: @err).run }
      assert_equal "not a directory: #{dir}", error.message
    end
  end

  private

  # Returns the output of this run alone.
  def sync(remote, server: SERVER)
    before = @out.string.size
    Sync.new(@dir, remote, server: server, out: @out, err: @err).run
    @out.string[before..]
  end

  # A remote and a directory both holding +contents+ after a first sync, the
  # local files and blobs dated T0.
  def synced_with(contents)
    contents.each { |key, content| write(key, content, mtime: T0) }
    remote = FakeRemote.new(contents.transform_values { |content| [content, T0] })
    sync(remote)
    remote
  end

  def path(key)
    File.join(@dir, key)
  end

  def write(key, content, mtime: nil)
    FileUtils.mkdir_p(File.dirname(path(key)))
    File.binwrite(path(key), content)
    File.utime(mtime, mtime, path(key)) if mtime
  end

  def sha(content)
    Digest::SHA256.hexdigest(content)
  end

  def state
    JSON.parse(File.read(path(".syncbox/state.json")))
  end

  # The user's regular files under the directory: {key => content}.
  def local_files
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir)
       .reject { |key| key == ".syncbox" || key.start_with?(".syncbox/") }
       .select { |key| File.file?(path(key)) && !File.symlink?(path(key)) }
       .to_h { |key| [key, File.binread(path(key))] }
  end
end
