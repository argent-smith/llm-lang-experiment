# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"
require "time"

class BlobStoreTest < Minitest::Test
  include TestHelpers

  BlobStore = Syncbox::Server::BlobStore

  def with_store
    with_tmpdir { |dir| yield BlobStore.new(dir), dir }
  end

  def put(store, key, data)
    store.put(key, StringIO.new(data.b))
  end

  def read(store, key)
    store.open(key) { |file, _size| file.read }
  end

  def test_put_stores_bytes_and_returns_metadata
    with_store do |store|
      meta = put(store, "docs/readme.txt", "hello")
      assert_equal "docs/readme.txt", meta.key
      assert_equal 5, meta.size
      assert_equal Digest::SHA256.hexdigest("hello"), meta.sha256
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, meta.modified_at)
      assert_equal "hello", read(store, "docs/readme.txt")
    end
  end

  def test_put_overwrites_existing_blob
    with_store do |store|
      put(store, "k", "one")
      put(store, "k", "two")
      assert_equal "two", read(store, "k")
      assert_equal 1, store.list.size
    end
  end

  def test_put_accepts_empty_and_missing_bodies
    with_store do |store|
      assert_equal 0, put(store, "empty", "").size
      assert_equal Digest::SHA256.hexdigest(""), store.put("none", nil).sha256
      assert_equal "", read(store, "none")
    end
  end

  def test_put_handles_binary_content
    with_store do |store|
      data = (0..255).map(&:chr).join.b * 1000
      meta = put(store, "bin", data)
      assert_equal data.bytesize, meta.size
      assert_equal data, read(store, "bin")
    end
  end

  def test_files_live_under_blobs_and_no_temp_files_remain
    with_store do |store, dir|
      put(store, "a/b/c", "x")
      assert File.file?(File.join(dir, "blobs", "a", "b", "c"))
      assert_empty Dir.children(File.join(dir, "tmp"))
    end
  end

  def test_open_and_delete_missing_blob_raise_not_found
    with_store do |store|
      assert_raises(BlobStore::NotFound) { read(store, "nope") }
      assert_raises(BlobStore::NotFound) { store.delete("nope") }
    end
  end

  def test_delete_removes_blob
    with_store do |store, dir|
      put(store, "k", "v")
      assert_nil store.delete("k")
      refute File.exist?(File.join(dir, "blobs", "k"))
      assert_raises(BlobStore::NotFound) { read(store, "k") }
      assert_empty store.list
    end
  end

  def test_delete_leaves_other_blobs_alone
    with_store do |store|
      put(store, "a/x", "ax")
      put(store, "a/y", "ay")
      put(store, "b", "b")
      store.delete("a/x")
      assert_equal ["a/y", "b"], store.list.map(&:key)
      assert_equal "ay", read(store, "a/y")
    end
  end

  def test_delete_prunes_emptied_parent_directories_up_to_the_root
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      put(store, "a/b/c/leaf", "v")
      put(store, "a/other", "o")

      store.delete("a/b/c/leaf")
      refute File.exist?(File.join(root, "a", "b"))
      assert File.directory?(File.join(root, "a"))

      store.delete("a/other")
      refute File.exist?(File.join(root, "a"))
      assert File.directory?(root)
      assert_equal [], store.list
    end
  end

  def test_delete_keeps_directories_that_still_hold_anything
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      put(store, "d/leaf", "v")
      FileUtils.mkdir_p(File.join(root, "d", "empty-subdir"))

      store.delete("d/leaf")
      assert File.directory?(File.join(root, "d")), "d/ is not empty (holds a directory)"
      assert File.directory?(File.join(root, "d", "empty-subdir"))
    end
  end

  def test_key_freed_by_delete_is_reusable_in_either_shape
    with_store do |store|
      put(store, "docs/readme.txt", "v")
      store.delete("docs/readme.txt")
      put(store, "docs", "file")
      assert_equal "file", read(store, "docs")

      store.delete("docs")
      put(store, "docs/readme.txt", "again")
      assert_equal "again", read(store, "docs/readme.txt")
      assert_equal ["docs/readme.txt"], store.list.map(&:key)
    end
  end

  def test_delete_of_a_dangling_symlink_is_not_found
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      FileUtils.mkdir_p(root)
      File.symlink(File.join(dir, "nowhere"), File.join(root, "dangling"))
      assert_raises(BlobStore::NotFound) { store.delete("dangling") }
      assert File.symlink?(File.join(root, "dangling"))
    end
  end

  def test_delete_does_not_touch_the_staging_area
    with_store do |store, dir|
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      File.write(File.join(dir, "tmp", "put-in-progress"), "half")
      put(store, "k", "v")
      store.delete("k")
      assert_equal ["put-in-progress"], Dir.children(File.join(dir, "tmp"))
    end
  end

  def test_concurrent_deletes_of_the_same_key_succeed_exactly_once
    with_store do |store|
      put(store, "k", "v")
      results = Array.new(8) do
        Thread.new do
          store.delete("k")
          :deleted
        rescue BlobStore::NotFound
          :not_found
        end
      end.map(&:value)
      assert_equal 1, results.count(:deleted), results.inspect
      assert_equal 7, results.count(:not_found)
    end
  end

  def test_concurrent_put_and_delete_in_one_directory_never_lose_the_put
    with_store do |store|
      50.times do |i|
        put(store, "shared/victim-#{i}", "v")
        deleter = Thread.new { store.delete("shared/victim-#{i}") }
        writer = Thread.new { put(store, "shared/kept-#{i}", "k") }
        [deleter, writer].each(&:join)
        assert_equal "k", read(store, "shared/kept-#{i}")
        store.delete("shared/kept-#{i}")
      end
      assert_equal [], store.list
    end
  end

  def test_directory_is_not_a_blob
    with_store do |store|
      put(store, "dir/file", "v")
      assert_raises(BlobStore::NotFound) { read(store, "dir") }
      assert_raises(BlobStore::NotFound) { store.delete("dir") }
    end
  end

  def test_list_returns_sorted_metadata
    with_store do |store|
      put(store, "b", "bb")
      put(store, "a/x", "a")
      put(store, ".hidden", "h")
      list = store.list
      assert_equal [".hidden", "a/x", "b"], list.map(&:key)
      assert_equal [1, 1, 2], list.map(&:size)
      assert_equal Digest::SHA256.hexdigest("bb"), list.last.sha256
    end
  end

  def test_list_is_empty_for_fresh_store
    with_store { |store| assert_equal [], store.list }
  end

  def test_list_walks_hidden_directories_and_skips_what_is_not_a_blob
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      put(store, "plain", "y")
      FileUtils.mkdir_p(File.join(root, ".hidden", "deep"))
      File.write(File.join(root, ".hidden", "deep", "f"), "x")
      FileUtils.mkdir_p(File.join(root, "empty", "nested"))
      File.binwrite(File.join(root, "\xFFnot-utf8".b), "q")
      File.symlink("/", File.join(root, "dir-link"))
      File.write(File.join(dir, "tmp", "put-in-progress"), "half")

      assert_equal [".hidden/deep/f", "plain"], store.list.map(&:key)
    end
  end

  def test_list_sees_blobs_written_directly_to_disk
    with_store do |store, dir|
      FileUtils.mkdir_p(File.join(dir, "blobs", "ext", "sub"))
      File.binwrite(File.join(dir, "blobs", "ext", "sub", "file.bin"), "\x00\x01\x02")

      list = store.list
      assert_equal ["ext/sub/file.bin"], list.map(&:key)
      assert_equal 3, list.first.size
      assert_equal Digest::SHA256.hexdigest("\x00\x01\x02".b), list.first.sha256
      assert_equal "\x00\x01\x02".b, read(store, "ext/sub/file.bin")
    end
  end

  def test_list_metadata_matches_the_file_on_disk
    with_store do |store, dir|
      put(store, "docs/readme.txt", "hello")
      path = File.join(dir, "blobs", "docs", "readme.txt")
      past = Time.utc(2024, 2, 29, 12, 34, 56, 789_000)
      File.utime(past, past, path)

      meta = store.list.fetch(0)
      assert_equal File.size(path), meta.size
      assert_equal Digest::SHA256.file(path).hexdigest, meta.sha256
      assert_equal File.mtime(path).floor(3), Time.iso8601(meta.modified_at)
      assert_equal(
        { key: "docs/readme.txt", size: 5, sha256: Digest::SHA256.hexdigest("hello"),
          modified_at: "2024-02-29T12:34:56.789Z" },
        meta.to_h
      )
    end
  end

  INVALID_KEYS = [
    "", "/", "/abs", "a/", "a//b", "..", "../x", "a/../b", "a/..", ".", "./a", "a/./b",
    "nul\0byte", "\xED\xA0\x80".b, "\xFF".b, "x" * 256, "a/#{'y' * 256}/b"
  ].freeze

  def test_invalid_keys_are_rejected_before_touching_disk
    with_store do |store, dir|
      INVALID_KEYS.each do |key|
        assert_raises(BlobStore::InvalidKey, "put #{key.inspect}") { put(store, key, "x") }
        assert_raises(BlobStore::InvalidKey, "open #{key.inspect}") { read(store, key) }
        assert_raises(BlobStore::InvalidKey, "delete #{key.inspect}") { store.delete(key) }
      end
      assert_empty Dir.glob(File.join(dir, "blobs", "**", "*"), File::FNM_DOTMATCH).reject { |p| p.end_with?("/.") }
    end
  end

  def test_unusual_but_representable_keys_are_accepted
    with_store do |store|
      ["0", "...", "a b", "ümlaut/日本語.txt", "weird\\name", "tab\tchar", "x" * 255, "-", "~", "a:b"].each do |key|
        put(store, key, key)
        assert_equal key.b, read(store, key), key.inspect
      end
    end
  end

  def test_key_colliding_with_existing_file_as_directory_is_invalid
    with_store do |store|
      put(store, "a", "file")
      assert_raises(BlobStore::InvalidKey) { put(store, "a/b", "x") }
      assert_raises(BlobStore::NotFound) { read(store, "a/b") }
      assert_raises(BlobStore::NotFound) { store.delete("a/b") }
      assert_equal "file", read(store, "a")
    end
  end

  def test_key_colliding_with_existing_directory_is_invalid
    with_store do |store|
      put(store, "a/b", "x")
      assert_raises(BlobStore::InvalidKey) { put(store, "a", "file") }
      assert_equal "x", read(store, "a/b")
    end
  end

  def test_concurrent_puts_to_different_keys_do_not_corrupt_each_other
    with_store do |store|
      payloads = Array.new(16) { |i| [(i.to_s * 20_000), "k#{i}"] }
      payloads.map { |data, key| Thread.new { put(store, key, data) } }.each(&:join)
      payloads.each do |data, key|
        assert_equal data, read(store, key)
      end
    end
  end

  def test_concurrent_puts_to_same_key_leave_one_intact_version
    with_store do |store|
      versions = Array.new(8) { |i| i.to_s * 50_000 }
      versions.map { |data| Thread.new { put(store, "same", data) } }.each(&:join)
      assert_includes versions, read(store, "same")
    end
  end

  # --- directory traversal protection (ticket 5) ---------------------------

  TRAVERSAL_KEYS = [
    "..", "../secret", "a/../../secret", "a/b/../../../secret", "../blobs/x", "/secret", "//secret",
    "/#{'../' * 8}etc/passwd", "#{'../' * 8}etc/passwd", "./../secret", "a/./../../secret"
  ].freeze

  def plant_secret(dir)
    File.write(File.join(dir, "secret"), "s3cret")
  end

  def test_traversal_keys_are_rejected_on_every_operation_even_when_the_target_exists
    with_store do |store, dir|
      plant_secret(dir)
      TRAVERSAL_KEYS.each do |key|
        assert_raises(BlobStore::InvalidKey, "put #{key.inspect}") { put(store, key, "planted") }
        assert_raises(BlobStore::InvalidKey, "open #{key.inspect}") { read(store, key) }
        assert_raises(BlobStore::InvalidKey, "delete #{key.inspect}") { store.delete(key) }
      end
      assert_equal "s3cret", File.read(File.join(dir, "secret")), "file outside the root must be untouched"
      assert_equal ["secret"], Dir.children(dir), "nothing may be created anywhere by a rejected key"
      assert_equal [], Dir.glob("**/*", File::FNM_DOTMATCH, base: File.join(dir, "blobs")).reject { |p| p.end_with?(".") }
    end
  end

  def test_dot_dot_inside_a_segment_is_an_ordinary_name
    with_store do |store|
      ["...", "a..b", "..a", "a..", "dir../x", "x/..y"].each do |key|
        put(store, key, key)
        assert_equal key.b, read(store, key), key.inspect
      end
      assert_equal ["...", "..a", "a..", "a..b", "dir../x", "x/..y"], store.list.map(&:key)
    end
  end

  def test_keys_that_cannot_be_file_names_are_rejected
    with_store do |store, dir|
      [
        "\xC0\xAE\xC0\xAE".b,          # overlong UTF-8 encoding of ".."
        "\xC0\xAE\xC0\xAE/x".b,
        "\xED\xA0\x80".b,              # UTF-16 surrogate half
        "\xF4\x90\x80\x80".b,          # above U+10FFFF
        "\xC3".b,                      # truncated multibyte sequence
        "ok/\xFF".b,
        "nul\0byte", "\0", "a/\0",
        "x" * 256, "#{'x' * 256}/y", "y/#{'x' * 256}"
      ].each do |key|
        assert_raises(BlobStore::InvalidKey, "put #{key.inspect}") { put(store, key, "x") }
        assert_raises(BlobStore::InvalidKey, "open #{key.inspect}") { read(store, key) }
        assert_raises(BlobStore::InvalidKey, "delete #{key.inspect}") { store.delete(key) }
      end
      assert_equal [], store.list
      assert_equal [], Dir.glob("**/*", File::FNM_DOTMATCH, base: File.join(dir, "blobs")).reject { |p| p.end_with?(".") }
    end
  end

  def test_symlinked_directory_leading_out_of_the_root_is_rejected
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p(root)
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "secret"), "s3cret")
      File.symlink(outside, File.join(root, "link"))

      assert_raises(BlobStore::InvalidKey) { read(store, "link/secret") }
      assert_raises(BlobStore::InvalidKey) { store.delete("link/secret") }
      assert_raises(BlobStore::InvalidKey) { put(store, "link/planted", "pwned") }
      assert_raises(BlobStore::InvalidKey) { put(store, "link/deeper/planted", "pwned") }
      assert_raises(BlobStore::InvalidKey) { read(store, "link") }
      assert_raises(BlobStore::InvalidKey) { store.delete("link") }
      assert_equal ["secret"], Dir.children(outside)
      assert_equal "s3cret", File.read(File.join(outside, "secret"))
      assert File.symlink?(File.join(root, "link")), "the link itself must be left alone"
      assert_equal [], store.list
    end
  end

  def test_symlinked_file_leading_out_of_the_root_is_rejected_and_not_listed
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      FileUtils.mkdir_p(root)
      File.write(File.join(dir, "secret"), "s3cret")
      File.symlink(File.join(dir, "secret"), File.join(root, "flink"))
      File.symlink("/", File.join(root, "rootlink"))
      put(store, "real", "r")

      assert_raises(BlobStore::InvalidKey) { read(store, "flink") }
      assert_raises(BlobStore::InvalidKey) { store.delete("flink") }
      assert_raises(BlobStore::InvalidKey) { put(store, "flink", "overwritten?") }
      assert_raises(BlobStore::InvalidKey) { read(store, "rootlink/etc/hostname") }
      assert_equal "s3cret", File.read(File.join(dir, "secret"))
      assert_equal ["real"], store.list.map(&:key)
    end
  end

  def test_symlink_to_the_root_itself_is_not_strictly_inside
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      FileUtils.mkdir_p(root)
      File.symlink(".", File.join(root, "self"))
      File.symlink(root, File.join(root, "abs-self"))
      put(store, "k", "v")

      assert_raises(BlobStore::InvalidKey) { read(store, "self") }
      assert_raises(BlobStore::InvalidKey) { store.delete("abs-self") }
      assert_raises(BlobStore::InvalidKey) { put(store, "self", "x") }
      # Through the link the key lands back inside the root, which is fine.
      assert_equal "v", read(store, "self/k")
      assert_equal ["k"], store.list.map(&:key)
    end
  end

  def test_symlink_cycle_resolves_nowhere_and_is_never_fatal
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      FileUtils.mkdir_p(root)
      File.symlink("loop-b", File.join(root, "loop-a"))
      File.symlink("loop-a", File.join(root, "loop-b"))

      # A cycle cannot lead out of the root, so it is simply not a blob (and
      # cannot be turned into a directory).
      assert_raises(BlobStore::NotFound) { read(store, "loop-a/x") }
      assert_raises(BlobStore::NotFound) { store.delete("loop-b/x") }
      assert_raises(BlobStore::InvalidKey) { put(store, "loop-a/x", "v") }
      assert_equal [], store.list
      assert File.symlink?(File.join(root, "loop-a"))
    end
  end

  def test_symlink_staying_inside_the_root_is_allowed
    with_store do |store, dir|
      root = File.join(dir, "blobs")
      put(store, "real/file", "content")
      File.symlink("real", File.join(root, "alias"))
      File.symlink(File.join(root, "real", "file"), File.join(root, "shortcut"))

      assert_equal "content", read(store, "alias/file")
      assert_equal "content", read(store, "shortcut")
      put(store, "alias/second", "two")
      assert File.file?(File.join(root, "real", "second"))
      # The listing never descends into symlinked directories (glob semantics),
      # but a symlinked file inside the root is a blob like any other.
      assert_equal ["real/file", "real/second", "shortcut"], store.list.map(&:key)
    end
  end

  def test_store_reached_through_a_symlinked_data_dir_works
    with_tmpdir do |dir|
      actual = File.join(dir, "actual")
      FileUtils.mkdir_p(actual)
      File.symlink(actual, File.join(dir, "via-link"))
      store = BlobStore.new(File.join(dir, "via-link"))

      put(store, "docs/readme.txt", "hello")
      assert_equal "hello", read(store, "docs/readme.txt")
      assert File.file?(File.join(actual, "blobs", "docs", "readme.txt"))
      assert_equal ["docs/readme.txt"], store.list.map(&:key)
      store.delete("docs/readme.txt")
      assert_raises(BlobStore::InvalidKey) { read(store, "../actual/blobs/x") }
    end
  end

  def test_validation_does_not_create_anything_on_disk
    with_store do |store, dir|
      (TRAVERSAL_KEYS + ["deep/never/created", "\xFF".b]).each do |key|
        store.delete(key)
      rescue BlobStore::InvalidKey, BlobStore::NotFound
        # expected
      end
      assert_equal [], Dir.children(dir)
    end
  end
end
