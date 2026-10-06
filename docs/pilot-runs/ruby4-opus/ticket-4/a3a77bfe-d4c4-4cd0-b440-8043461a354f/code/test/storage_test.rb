# frozen_string_literal: true

require "test_helper"
require "digest"

class StorageTest < Minitest::Test
  def setup
    @data_dir = Dir.mktmpdir
    @blobs_dir = File.join(@data_dir, "blobs")
  end

  def teardown
    FileUtils.rm_rf(@data_dir)
  end

  def test_list_without_blobs_directory_is_empty
    assert_equal [], Syncbox::Server::Storage.new(@data_dir).list
  end

  def test_list_reports_blobs_found_on_disk
    content = Random.new(1).bytes(3 * Syncbox::Server::Storage::CHUNK_SIZE + 7)
    write_blob("docs/readme.txt", "hello")
    write_blob("docs/img/data.bin", content)
    write_blob("empty", "")
    mtime = Time.utc(2026, 1, 2, 3, 4, 5, 678_901)
    File.utime(mtime, mtime, File.join(@blobs_dir, "docs/readme.txt"))
    Dir.mkdir(File.join(@blobs_dir, "no-blobs-here"))

    assert_equal [
      { key: "docs/img/data.bin", size: content.bytesize, sha256: Digest::SHA256.hexdigest(content) },
      { key: "docs/readme.txt", size: 5, sha256: Digest::SHA256.hexdigest("hello") },
      { key: "empty", size: 0, sha256: Digest::SHA256.hexdigest("") }
    ], storage.list.map { |blob| blob.slice(:key, :size, :sha256) }
    assert_equal "2026-01-02T03:04:05.678901Z", storage.list.find { |blob| blob[:key] == "docs/readme.txt" }[:modified_at]
  end

  def test_list_survives_directory_replaced_by_blob
    write_blob("a/x", "x")
    write_blob("b", "y")
    racing = racing_storage(:each_entry) do |dir|
      next unless dir == File.join(@blobs_dir, "a")

      # DELETE a/x prunes a/, then PUT a stores a blob in its place.
      FileUtils.rm_rf(dir)
      File.binwrite(dir, "z")
    end

    assert_equal %w[b], racing.list.map { |blob| blob[:key] }
  end

  def test_list_survives_blob_replaced_by_directory
    write_blob("a", "x")
    write_blob("b", "y")
    racing = racing_storage(:metadata) do |key, path|
      next unless key == "a"

      # DELETE a, then PUT a/x.
      File.unlink(path)
      write_blob("a/x", "z")
    end

    assert_equal %w[b], racing.list.map { |blob| blob[:key] }
  end

  def test_list_survives_blob_replaced_by_symlink
    write_blob("a", "x")
    write_blob("b", "y")
    racing = racing_storage(:metadata) do |key, path|
      next unless key == "a"

      File.unlink(path)
      File.symlink("/etc/passwd", path)
    end

    assert_equal %w[b], racing.list.map { |blob| blob[:key] }
  end

  private

  def storage
    Syncbox::Server::Storage.new(@data_dir)
  end

  def write_blob(key, content)
    path = File.join(@blobs_dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  # A Storage that runs +hook+ with the arguments of the private step
  # +method+ right before that step, to replay a concurrent request.
  def racing_storage(method, &hook)
    Class.new(Syncbox::Server::Storage) do
      define_method(method) do |*args, &block|
        hook.call(*args)
        super(*args, &block)
      end
      private method
    end.new(@data_dir)
  end
end
