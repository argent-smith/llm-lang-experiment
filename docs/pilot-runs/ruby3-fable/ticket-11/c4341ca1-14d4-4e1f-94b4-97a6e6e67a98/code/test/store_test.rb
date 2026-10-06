# frozen_string_literal: true

require "test_helper"
require "stringio"

# Юнит-тесты хранилища блобов (тикет 2: happy path PUT/GET).
class StoreTest < Minitest::Test
  CHUNK = Syncbox::Store::CHUNK_SIZE

  def setup
    @data_dir = Dir.mktmpdir("syncbox-store")
    @store = Syncbox::Store.new(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && File.exist?(@data_dir)
  end

  def read_all(key)
    size, body = @store.open(key)
    chunks = []
    body.each { |chunk| chunks << chunk }
    [size, chunks]
  ensure
    body&.close
  end

  def test_put_returns_key_sha256_and_size
    result = @store.put("hello.txt", StringIO.new("hello"))
    assert_equal({ "key" => "hello.txt", "sha256" => Digest::SHA256.hexdigest("hello"), "size" => 5 }, result)
    assert_match(/\A[0-9a-f]{64}\z/, result["sha256"])
    assert_equal "hello", File.binread(File.join(@data_dir, "hello.txt"))
  end

  def test_put_creates_intermediate_directories
    @store.put("docs/guides/2026/readme.txt", StringIO.new("nested"))
    %w[docs docs/guides docs/guides/2026].each do |dir|
      assert File.directory?(File.join(@data_dir, dir)), "#{dir} should be created"
    end
    assert_equal "nested", File.binread(File.join(@data_dir, "docs/guides/2026/readme.txt"))
  end

  def test_put_streams_body_larger_than_chunk_size
    payload = Random.new(42).bytes(CHUNK * 3 + 17)
    result = @store.put("big.bin", StringIO.new(payload))
    assert_equal payload.bytesize, result["size"]
    assert_equal Digest::SHA256.hexdigest(payload), result["sha256"]
    assert_equal payload, File.binread(File.join(@data_dir, "big.bin"))
  end

  def test_put_empty_body
    result = @store.put("empty", StringIO.new(""))
    assert_equal({ "key" => "empty", "sha256" => Digest::SHA256.hexdigest(""), "size" => 0 }, result)
    assert_equal 0, File.size(File.join(@data_dir, "empty"))
  end

  def test_put_overwrites_existing_blob_and_reports_new_metadata
    @store.put("k", StringIO.new("first version"))
    result = @store.put("k", StringIO.new("v2"))
    assert_equal({ "key" => "k", "sha256" => Digest::SHA256.hexdigest("v2"), "size" => 2 }, result)
    assert_equal "v2", File.binread(File.join(@data_dir, "k"))
  end

  def test_put_leaves_no_temp_files_behind
    @store.put("a/b", StringIO.new("x"))
    tmp_dir = File.join(@data_dir, Syncbox::Store::TMP_DIR)
    assert_empty Dir.children(tmp_dir)
  end

  def test_open_returns_size_and_byte_identical_body
    payload = Random.new(7).bytes(CHUNK * 2 + 1)
    @store.put("dir/data.bin", StringIO.new(payload))

    size, chunks = read_all("dir/data.bin")
    assert_equal payload.bytesize, size
    assert_equal payload, chunks.join.b
    assert_operator chunks.length, :>, 1, "body should be streamed in chunks"
  end

  def test_open_body_close_releases_file
    @store.put("c", StringIO.new("x"))
    _size, body = @store.open("c")
    file = body.instance_variable_get(:@file)
    refute file.closed?
    body.close
    assert file.closed?
    body.close # повторный close безопасен
  end

  def test_open_missing_key_raises_not_found
    assert_raises(Syncbox::Store::NotFound) { @store.open("missing") }
  end

  def test_open_missing_key_in_missing_directory_raises_not_found
    assert_raises(Syncbox::Store::NotFound) { @store.open("no/such/dir/file") }
  end

  def test_open_missing_key_next_to_existing_blob_raises_not_found
    @store.put("docs/a.txt", StringIO.new("a"))
    assert_raises(Syncbox::Store::NotFound) { @store.open("docs/b.txt") }
  end
end

# Юнит-тесты списка блобов (тикет 3: GET /blobs).
class StoreListTest < Minitest::Test
  CHUNK = Syncbox::Store::CHUNK_SIZE
  ISO8601_UTC = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  def setup
    @data_dir = Dir.mktmpdir("syncbox-list")
    @store = Syncbox::Store.new(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && File.exist?(@data_dir)
  end

  def write_on_disk(rel, content)
    path = File.join(@data_dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def test_empty_store_lists_nothing
    assert_equal [], @store.list
  end

  def test_store_with_only_empty_dirs_and_tmp_dir_lists_nothing
    FileUtils.mkdir_p(File.join(@data_dir, "a", "b"))
    FileUtils.mkdir_p(File.join(@data_dir, Syncbox::Store::TMP_DIR))
    File.write(File.join(@data_dir, Syncbox::Store::TMP_DIR, "leftover.tmp"), "x")
    assert_equal [], @store.list
  end

  def test_list_returns_metadata_for_every_blob_sorted_by_key
    @store.put("docs/readme.txt", StringIO.new("hello"))
    @store.put("b.bin", StringIO.new("\x00\xff".b))
    @store.put("a/deep/er/file", StringIO.new(""))

    list = @store.list
    assert_equal ["a/deep/er/file", "b.bin", "docs/readme.txt"], list.map { |m| m["key"] }

    readme = list.find { |m| m["key"] == "docs/readme.txt" }
    assert_equal %w[key modified_at sha256 size], readme.keys.sort
    assert_equal 5, readme["size"]
    assert_equal Digest::SHA256.hexdigest("hello"), readme["sha256"]
    assert_match ISO8601_UTC, readme["modified_at"]

    empty = list.find { |m| m["key"] == "a/deep/er/file" }
    assert_equal 0, empty["size"]
    assert_equal Digest::SHA256.hexdigest(""), empty["sha256"]
  end

  def test_sha256_is_lowercase_hex_and_size_is_byte_count_for_large_blob
    payload = Random.new(3).bytes(CHUNK * 2 + 5)
    @store.put("big", StringIO.new(payload))
    meta = @store.list.first
    assert_match(/\A[0-9a-f]{64}\z/, meta["sha256"])
    assert_equal Digest::SHA256.hexdigest(payload), meta["sha256"]
    assert_equal payload.bytesize, meta["size"]
  end

  def test_modified_at_is_file_mtime_in_utc
    path = write_on_disk("stamped", "x")
    File.utime(Time.now, Time.utc(2024, 2, 29, 23, 59, 58), path)

    meta = @store.list.first
    assert_equal "2024-02-29T23:59:58Z", meta["modified_at"]
    assert_equal File.mtime(path).utc.iso8601, meta["modified_at"]
  end

  def test_modified_at_after_put_is_close_to_now
    before = Time.now.utc - 1
    @store.put("fresh", StringIO.new("x"))
    at = Time.iso8601(@store.list.first["modified_at"])
    assert_operator at, :>=, Time.at(before.to_i).utc
    assert_operator at, :<=, Time.now.utc + 1
  end

  def test_list_includes_blobs_written_to_disk_outside_the_api
    write_on_disk("ext/plain.txt", "from disk")
    meta = @store.list.first
    assert_equal "ext/plain.txt", meta["key"]
    assert_equal 9, meta["size"]
    assert_equal Digest::SHA256.hexdigest("from disk"), meta["sha256"]
  end

  def test_list_includes_dot_files_and_dot_directories
    @store.put(".env", StringIO.new("a"))
    @store.put(".git/config", StringIO.new("b"))
    assert_equal [".env", ".git/config"], @store.list.map { |m| m["key"] }
  end

  def test_list_includes_keys_with_unicode_and_spaces
    @store.put("dir name/привет.txt", StringIO.new("x"))
    assert_equal ["dir name/привет.txt"], @store.list.map { |m| m["key"] }
  end

  def test_list_skips_entries_that_are_not_regular_files_or_valid_keys
    @store.put("ok", StringIO.new("x"))
    FileUtils.mkdir_p(File.join(@data_dir, "just-a-dir"))
    File.binwrite(File.join(@data_dir, "bad\xff".b), "x")
    File.mkfifo(File.join(@data_dir, "pipe"))
    FileUtils.mkdir_p(File.join(@data_dir, Syncbox::Store::TMP_DIR))
    File.write(File.join(@data_dir, Syncbox::Store::TMP_DIR, "in-flight.tmp"), "x")

    assert_equal ["ok"], @store.list.map { |m| m["key"] }
  end

  def test_list_reflects_overwrite_and_delete
    @store.put("k", StringIO.new("one"))
    @store.put("other", StringIO.new("o"))
    @store.put("k", StringIO.new("second version"))
    meta = @store.list.find { |m| m["key"] == "k" }
    assert_equal 14, meta["size"]
    assert_equal Digest::SHA256.hexdigest("second version"), meta["sha256"]

    @store.delete("k")
    assert_equal ["other"], @store.list.map { |m| m["key"] }
  end

  # Подкласс, считающий, сколько раз #list хешировал файл с диска.
  class CountingStore < Syncbox::Store
    attr_reader :digests_computed

    def initialize(root)
      super
      @digests_computed = 0
    end

    private

    def digest_of(file)
      @digests_computed += 1
      super
    end
  end

  def test_list_reuses_digest_computed_by_put
    store = CountingStore.new(@data_dir)
    store.put("cached", StringIO.new("payload"))
    2.times { assert_equal Digest::SHA256.hexdigest("payload"), store.list.first["sha256"] }
    assert_equal 0, store.digests_computed, "digest must not be recomputed for an unchanged file"
  end

  def test_list_hashes_file_placed_on_disk_only_once_until_it_changes
    store = CountingStore.new(@data_dir)
    write_on_disk("ext", "data")
    3.times { assert_equal Digest::SHA256.hexdigest("data"), store.list.first["sha256"] }
    assert_equal 1, store.digests_computed
  end

  def test_list_recomputes_digest_when_file_changed_on_disk
    @store.put("k", StringIO.new("aaaa"))
    assert_equal Digest::SHA256.hexdigest("aaaa"), @store.list.first["sha256"]

    # Та же длина, тот же inode (запись на месте) — меняется только mtime.
    path = File.join(@data_dir, "k")
    File.binwrite(path, "bbbb")
    File.utime(Time.now, File.mtime(path) + 1, path)
    assert_equal Digest::SHA256.hexdigest("bbbb"), @store.list.first["sha256"]

    # Та же длина, тот же mtime — но другой inode (подмена через rename).
    mtime = File.mtime(path)
    replacement = write_on_disk("k.new", "cccc")
    File.utime(Time.now, mtime, replacement)
    File.rename(replacement, path)
    assert_equal Digest::SHA256.hexdigest("cccc"), @store.list.first["sha256"]
  end

  def test_list_recomputes_digest_after_key_is_deleted_and_recreated_on_disk
    @store.put("k", StringIO.new("one"))
    @store.list
    File.delete(File.join(@data_dir, "k"))
    assert_equal [], @store.list
    write_on_disk("k", "two")
    assert_equal Digest::SHA256.hexdigest("two"), @store.list.first["sha256"]
  end

  def test_list_is_safe_under_concurrent_puts
    threads = 4.times.map do |t|
      Thread.new do
        20.times { |i| @store.put("t#{t}/f#{i}", StringIO.new("#{t}-#{i}")) }
      end
    end
    listings = 5.times.map { @store.list }
    threads.each(&:join)

    listings.each do |list|
      list.each do |meta|
        assert_equal Digest::SHA256.hexdigest(meta["key"].delete_prefix("t").sub("/f", "-")), meta["sha256"]
      end
    end
    assert_equal 80, @store.list.length
  end
end

# Юнит-тесты удаления блоба (тикет 4: DELETE /blobs/{key}).
class StoreDeleteTest < Minitest::Test
  def setup
    @data_dir = Dir.mktmpdir("syncbox-delete")
    @store = Syncbox::Store.new(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && File.exist?(@data_dir)
  end

  def write_on_disk(rel, content)
    path = File.join(@data_dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def test_delete_removes_file_and_returns_nil
    @store.put("hello.txt", StringIO.new("hello"))
    assert_nil @store.delete("hello.txt")
    refute File.exist?(File.join(@data_dir, "hello.txt"))
    assert File.directory?(@data_dir), "data dir itself must survive"
  end

  def test_deleted_blob_is_gone_from_open_and_list
    @store.put("docs/readme.txt", StringIO.new("hello"))
    @store.put("other", StringIO.new("o"))
    @store.list

    @store.delete("docs/readme.txt")
    assert_raises(Syncbox::Store::NotFound) { @store.open("docs/readme.txt") }
    assert_equal ["other"], @store.list.map { |m| m["key"] }
  end

  def test_delete_missing_key_raises_not_found
    assert_raises(Syncbox::Store::NotFound) { @store.delete("missing") }
    assert_raises(Syncbox::Store::NotFound) { @store.delete("no/such/dir/file") }
  end

  def test_delete_twice_raises_not_found_second_time
    @store.put("once", StringIO.new("x"))
    @store.delete("once")
    assert_raises(Syncbox::Store::NotFound) { @store.delete("once") }
  end

  def test_delete_missing_key_next_to_existing_blob_raises_not_found_and_keeps_neighbour
    @store.put("docs/a.txt", StringIO.new("a"))
    assert_raises(Syncbox::Store::NotFound) { @store.delete("docs/b.txt") }
    assert_equal "a", File.binread(File.join(@data_dir, "docs", "a.txt"))
  end

  def test_delete_key_that_is_a_directory_raises_not_found_and_keeps_contents
    @store.put("dir/child", StringIO.new("x"))
    assert_raises(Syncbox::Store::NotFound) { @store.delete("dir") }
    assert_equal "x", File.binread(File.join(@data_dir, "dir", "child"))
  end

  def test_delete_key_under_existing_file_raises_not_found
    @store.put("file", StringIO.new("x"))
    assert_raises(Syncbox::Store::NotFound) { @store.delete("file/child") }
    assert_equal "x", File.binread(File.join(@data_dir, "file"))
  end

  def test_delete_validates_key
    assert_raises(Syncbox::Store::InvalidKey) { @store.delete("") }
    assert_raises(Syncbox::Store::InvalidKey) { @store.delete("../etc/passwd") }
    assert_raises(Syncbox::Store::InvalidKey) { @store.delete("/abs") }
    assert_raises(Syncbox::Store::InvalidKey) { @store.delete("#{Syncbox::Store::TMP_DIR}/x") }
  end

  def test_delete_prunes_empty_parent_directories_up_to_root
    @store.put("a/b/c/file", StringIO.new("x"))
    @store.delete("a/b/c/file")
    refute File.exist?(File.join(@data_dir, "a")), "empty ancestors should be removed"
    assert File.directory?(@data_dir)
  end

  def test_delete_keeps_directories_that_still_have_content
    @store.put("a/b/one", StringIO.new("1"))
    @store.put("a/b/two", StringIO.new("2"))
    @store.put("a/x", StringIO.new("x"))

    @store.delete("a/b/one")
    assert File.file?(File.join(@data_dir, "a", "b", "two"))

    @store.delete("a/b/two")
    refute File.exist?(File.join(@data_dir, "a", "b")), "a/b became empty and should be pruned"
    assert File.file?(File.join(@data_dir, "a", "x")), "a still has content and must stay"
  end

  def test_key_can_be_reused_as_a_file_after_deleting_blobs_beneath_it
    @store.put("d/e/f", StringIO.new("x"))
    @store.delete("d/e/f")
    result = @store.put("d", StringIO.new("now a file"))
    assert_equal "d", result["key"]
    assert_equal "now a file", File.binread(File.join(@data_dir, "d"))
  end

  def test_delete_removes_file_placed_on_disk_outside_the_api
    write_on_disk("ext/plain.txt", "from disk")
    assert_equal ["ext/plain.txt"], @store.list.map { |m| m["key"] }
    @store.delete("ext/plain.txt")
    refute File.exist?(File.join(@data_dir, "ext"))
    assert_equal [], @store.list
  end

  def test_delete_forgets_cached_digest_so_recreated_key_is_rehashed
    @store.put("k", StringIO.new("one"))
    @store.delete("k")
    write_on_disk("k", "two")
    assert_equal Digest::SHA256.hexdigest("two"), @store.list.first["sha256"]
  end

  def test_delete_does_not_touch_temp_dir
    tmp_dir = File.join(@data_dir, Syncbox::Store::TMP_DIR)
    @store.put("k", StringIO.new("x"))
    assert File.directory?(tmp_dir)
    @store.delete("k")
    assert File.directory?(tmp_dir)
  end

  def test_concurrent_deletes_of_same_key_succeed_exactly_once
    @store.put("shared", StringIO.new("x"))
    outcomes = Queue.new
    threads = 8.times.map do
      Thread.new do
        @store.delete("shared")
        outcomes << :deleted
      rescue Syncbox::Store::NotFound
        outcomes << :not_found
      end
    end
    threads.each(&:join)
    results = Array.new(outcomes.size) { outcomes.pop }.tally
    assert_equal 1, results[:deleted]
    assert_equal 7, results[:not_found]
  end

  def test_concurrent_deletes_and_puts_in_same_directory_never_fail
    errors = Queue.new
    threads = 4.times.map do |t|
      Thread.new do
        50.times do |i|
          @store.put("shared/t#{t}-#{i}", StringIO.new("x"))
          @store.delete("shared/t#{t}-#{i}")
        end
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)
    assert_empty Array.new(errors.size) { errors.pop }
    assert_equal [], @store.list
  end

  # Хранилище, в котором родительский каталог исчезает сразу после создания —
  # так выглядит DELETE соседнего блоба, вклинившийся между mkdir_p и rename.
  class VanishingParentStore < Syncbox::Store
    attr_accessor :vanish_times

    private

    def ensure_parent_dir(target)
      super
      return unless vanish_times.positive?

      self.vanish_times -= 1
      prune_empty_dirs(File.dirname(target))
    end
  end

  def test_put_survives_parent_directory_pruned_by_concurrent_delete
    store = VanishingParentStore.new(@data_dir)
    store.vanish_times = Syncbox::Store::RENAME_ATTEMPTS - 1
    result = store.put("dir/sub/file", StringIO.new("x"))
    assert_equal "dir/sub/file", result["key"]
    assert_equal "x", File.binread(File.join(@data_dir, "dir", "sub", "file"))
    assert_empty Dir.children(File.join(@data_dir, Syncbox::Store::TMP_DIR))
  end

  def test_put_gives_up_when_parent_directory_keeps_vanishing
    store = VanishingParentStore.new(@data_dir)
    store.vanish_times = Syncbox::Store::RENAME_ATTEMPTS
    assert_raises(Errno::ENOENT) { store.put("dir/file", StringIO.new("x")) }
    assert_empty Dir.children(File.join(@data_dir, Syncbox::Store::TMP_DIR)), "temp file must be cleaned up"
  end
end
