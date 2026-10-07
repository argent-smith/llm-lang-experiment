# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

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

  def test_valid_key
    ["a", "docs/readme.txt", "...", "a..b", ".hidden", "a\\b", "~", "~root/x", "✓"].each do |key|
      assert Syncbox::Server::Storage.valid_key?(key), key
    end
    ["", "/", "/etc/passwd", "..", "../x", "a/..", "a/../../x", ".", "a/./b", "a//b", "a/",
     "..\\x", "a\\..\\..\\x", "a/..\\x", "\\x", "a\0b", "\xFF".b, "\xED\xA0\x80".dup.force_encoding(Encoding::UTF_8),
     "a" * 256].each do |key|
      refute Syncbox::Server::Storage.valid_key?(key), key.inspect
    end
  end

  def test_paths_leaving_the_store_are_rejected_even_if_the_key_check_misses_them
    lax = Class.new(Syncbox::Server::Storage) do
      def self.valid_key?(_key) = true
    end.new(@data_dir)
    File.binwrite(File.join(@data_dir, "outside"), "secret")

    ["../outside", "../blobs-outside", "/etc/passwd", "a/../../outside", ".", "a/.."].each do |key|
      assert_raises(Syncbox::Server::Storage::InvalidKey, key) { lax.put(key, StringIO.new("evil")) }
      assert_raises(Syncbox::Server::Storage::InvalidKey, key) { lax.open(key) }
      assert_raises(Syncbox::Server::Storage::InvalidKey, key) { lax.delete(key) }
    end
    assert_equal "secret", File.binread(File.join(@data_dir, "outside"))
    assert_equal %w[outside], Dir.children(@data_dir)
  end

  def test_put_into_a_symlink_to_a_directory_inside_the_store_is_allowed
    write_blob("real/a", "x")
    File.symlink("real", File.join(@blobs_dir, "alias"))

    storage.put("alias/b", StringIO.new("y"))

    assert_equal "y", File.binread(File.join(@blobs_dir, "real/b"))
  end

  def test_put_exposes_the_new_blob_only_once_complete
    storage.put("f", StringIO.new("old"))
    tmp_dir = File.join(@data_dir, "tmp")
    seen = []
    input = HookedInput.new("new content " * 20_000) do
      file = storage.open("f")
      seen << [file.read, storage.list.map { |blob| blob.slice(:key, :size) }, Dir.children(tmp_dir).size]
    ensure
      file&.close
    end

    storage.put("f", input)

    assert_operator seen.size, :>, 1, "the upload should take several reads"
    assert_equal [["old", [{ key: "f", size: 3 }], 1]], seen.uniq
    assert_equal "new content " * 20_000, File.binread(File.join(@blobs_dir, "f"))
    assert_equal [], Dir.children(tmp_dir)
  end

  def test_put_failing_mid_upload_keeps_the_old_blob_and_leaves_no_temporary_file
    storage.put("f", StringIO.new("old"))
    input = HookedInput.new("x" * 200_000) { |reads| raise EOFError, "client went away" if reads == 2 }

    assert_raises(EOFError) { storage.put("f", input) }
    assert_raises(EOFError) { storage.put("new/key", HookedInput.new("x" * 200_000) { raise EOFError }) }

    assert_equal "old", File.binread(File.join(@blobs_dir, "f"))
    assert_equal %w[f], storage.list.map { |blob| blob[:key] }
    assert_equal [], Dir.children(File.join(@data_dir, "tmp"))
  end

  def test_put_failing_after_the_upload_leaves_no_temporary_file
    racing = racing_storage(:make_parents) { raise Errno::ENOSPC }

    assert_raises(Errno::ENOSPC) { racing.put("a/b", StringIO.new("x")) }
    assert_equal [], Dir.children(File.join(@data_dir, "tmp"))
  end

  def test_concurrent_puts_to_one_key_never_expose_a_partial_blob
    versions = Array.new(4) { |i| Random.new(i).bytes(200_000 + i) }
    digests = versions.map { |content| Digest::SHA256.hexdigest(content) }
    storage.put("f", StringIO.new(versions[0]))
    done = false
    writers = versions.map do |content|
      Thread.new { 30.times { storage.put("f", StringIO.new(content)) } }
    end
    readers = Array.new(2) do
      Thread.new do
        digests_read = []
        until done
          file = storage.open("f")
          digests_read << Digest::SHA256.hexdigest(file.read)
          file.close
          digests_read.concat(storage.list.map { |blob| blob[:sha256] })
        end
        digests_read
      end
    end
    writers.each(&:join)
    done = true

    readers.flat_map(&:value).each { |digest| assert_includes digests, digest }
    assert_includes digests, Digest::SHA256.file(File.join(@blobs_dir, "f")).hexdigest
    assert_equal [], Dir.children(File.join(@data_dir, "tmp"))
  end

  def test_concurrent_puts_to_different_keys_do_not_interfere
    keys = Array.new(8) { |i| Array.new(20) { |j| "t#{i}/#{j % 3}/k#{j}" } }
    keys.map do |thread_keys|
      Thread.new { thread_keys.each { |key| storage.put(key, StringIO.new(key * 5_000)) } }
    end.each(&:join)

    blobs = storage.list

    assert_equal keys.flatten.sort, blobs.map { |blob| blob[:key] }
    blobs.each { |blob| assert_equal Digest::SHA256.hexdigest(blob[:key] * 5_000), blob[:sha256], blob[:key] }
    assert_equal [], Dir.children(File.join(@data_dir, "tmp"))
  end

  def test_prepare_creates_directories_and_removes_leftover_temporary_files
    tmp_dir = File.join(@data_dir, "tmp")
    FileUtils.mkdir_p(tmp_dir)
    File.binwrite(File.join(tmp_dir, "0123abcd"), "half an upload")
    write_blob("kept", "x")

    storage.prepare!

    assert_equal %w[blobs tmp], Dir.children(@data_dir).sort
    assert_equal [], Dir.children(tmp_dir)
    assert_equal %w[kept], storage.list.map { |blob| blob[:key] }
  end

  def test_prepare_rejects_blobs_on_another_file_system
    skip "no /dev/shm to put the blobs on" unless File.directory?("/dev/shm") && File.writable?("/dev/shm")
    other = Dir.mktmpdir(nil, "/dev/shm")
    skip "/dev/shm is on the same file system as #{@data_dir}" if File.stat(other).dev == File.stat(@data_dir).dev
    File.symlink(other, @blobs_dir)

    error = assert_raises(Syncbox::Server::Storage::Unusable) { storage.prepare! }
    assert_match(/same file system/, error.message)
  ensure
    FileUtils.rm_rf(other) if other
  end

  private

  # An upload body that calls +hook+ with the number of reads so far before
  # every read, the way a slow client would let other requests run meanwhile.
  class HookedInput
    def initialize(content, &hook)
      @io = StringIO.new(content)
      @hook = hook
      @reads = 0
    end

    def read(...)
      @hook.call(@reads += 1)
      @io.read(...)
    end
  end

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
