# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

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
    with_store do |store|
      put(store, "k", "v")
      store.delete("k")
      assert_raises(BlobStore::NotFound) { read(store, "k") }
      assert_empty store.list
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
end
