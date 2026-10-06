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
