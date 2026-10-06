# frozen_string_literal: true

require "test_helper"
require "stringio"

# Юнит-тесты атомарности записи (тикет 6): временный файл + rename,
# параллельные PUT по одному и разным key, уборка временных файлов.
class StoreAtomicWriteTest < Minitest::Test
  CHUNK = Syncbox::Store::CHUNK_SIZE
  TMP_DIR = Syncbox::Store::TMP_DIR

  def setup
    @data_dir = Dir.mktmpdir("syncbox-atomic")
    @tmp_dir = File.join(@data_dir, TMP_DIR)
    @store = Syncbox::Store.new(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && File.exist?(@data_dir)
  end

  def tmp_entries
    File.directory?(@tmp_dir) ? Dir.children(@tmp_dir) : []
  end

  def read_all(store, key)
    size, body = store.open(key)
    chunks = []
    body.each { |chunk| chunks << chunk }
    [size, chunks.join.b]
  ensure
    body&.close
  end

  def drain(queue)
    Array.new(queue.size) { queue.pop }
  end

  # Тело запроса, отдающее данные кусками с паузой между ними — окно, в
  # котором параллельный читатель застал бы недописанный файл, если бы
  # запись шла прямо в целевой путь.
  class SlowInput
    def initialize(data, pause: 0.001)
      @io = StringIO.new(data)
      @pause = pause
    end

    def read(length)
      chunk = @io.read(length)
      sleep(@pause) if chunk && @pause.positive?
      chunk
    end
  end

  # Тело запроса, обрывающееся после первых байт — обрыв соединения клиента
  # посреди загрузки.
  class BrokenInput
    def initialize(prefix)
      @io = StringIO.new(prefix)
    end

    def read(length)
      chunk = @io.read(length)
      raise IOError, "client disconnected" if chunk.nil?

      chunk
    end
  end

  # Хранилище, запоминающее состояние диска в момент перед rename.
  class ObservingStore < Syncbox::Store
    attr_reader :observed

    private

    def move_into_place(src, target)
      target_exists = File.file?(target)
      @observed = {
        tmp_path: src,
        tmp_content: File.binread(src),
        tmp_dev: File.stat(src).dev,
        tmp_ino: File.stat(src).ino,
        target_content: (File.binread(target) if target_exists),
        target_ino: (File.stat(target).ino if target_exists),
        listing: list.map { |m| m["key"] }
      }
      super
    end
  end

  # Хранилище, записывающее порядок шагов записи.
  class OrderRecordingStore < Syncbox::Store
    attr_reader :events

    def initialize(root)
      super
      @events = []
    end

    private

    def flush_to_disk(file)
      @events << [:fsync, file.closed? ? :closed : :open]
      super
    end

    def move_into_place(src, target)
      @events << [:rename, File.exist?(src), File.exist?(target)]
      super
    end
  end

  # --- временный файл + rename -------------------------------------------------

  def test_put_writes_whole_body_to_a_temp_file_in_the_tmp_dir_and_then_renames_it
    store = ObservingStore.new(@data_dir)
    store.put("docs/k", StringIO.new("old"))
    target = File.join(@data_dir, "docs", "k")
    old_ino = File.stat(target).ino

    payload = Random.new(1).bytes(CHUNK * 2 + 3)
    store.put("docs/k", StringIO.new(payload))
    seen = store.observed

    assert_equal @tmp_dir, File.dirname(seen[:tmp_path]), "temp file lives in the reserved tmp dir"
    assert seen[:tmp_path].end_with?(Syncbox::Store::TMP_SUFFIX)
    assert_equal File.stat(@data_dir).dev, seen[:tmp_dev], "temp file is on the same filesystem as the data dir"
    assert_equal payload, seen[:tmp_content], "temp file holds the whole body before rename"
    assert_equal "old", seen[:target_content], "target still holds the old version until rename"
    assert_equal old_ino, seen[:target_ino], "target inode is untouched until rename"

    assert_equal payload, File.binread(target)
    assert_equal seen[:tmp_ino], File.stat(target).ino, "rename moves the temp inode into place, no copy"
    refute File.exist?(seen[:tmp_path])
    assert_empty tmp_entries
  end

  def test_temp_file_is_fsynced_while_open_and_before_rename
    store = OrderRecordingStore.new(@data_dir)
    store.put("k", StringIO.new("x"))
    assert_equal [[:fsync, :open], [:rename, true, false]], store.events
  end

  def test_temp_file_is_not_listed_and_not_addressable_while_put_is_in_progress
    store = ObservingStore.new(@data_dir)
    store.put("other", StringIO.new("o"))
    store.put("new", StringIO.new("n"))
    seen = store.observed

    assert_equal ["other"], seen[:listing], "neither the temp file nor the not-yet-renamed key is listed"
    tmp_key = "#{TMP_DIR}/#{File.basename(seen[:tmp_path])}"
    assert_raises(Syncbox::Store::InvalidKey) { store.open(tmp_key) }
    assert_raises(Syncbox::Store::InvalidKey) { store.delete(tmp_key) }
    assert_raises(Syncbox::Store::InvalidKey) { store.open(TMP_DIR) }
  end

  def test_reader_that_opened_the_old_version_reads_it_completely_after_overwrite
    old = "a".b * (CHUNK * 3)
    new = "b".b * (CHUNK * 3 + 1)
    @store.put("k", StringIO.new(old))

    size, body = @store.open("k")
    @store.put("k", StringIO.new(new))
    chunks = []
    body.each { |chunk| chunks << chunk }
    body.close

    assert_equal old.bytesize, size
    assert_equal old, chunks.join.b, "an already open reader keeps reading the old version to the end"
    assert_equal [new.bytesize, new], read_all(@store, "k")
  end

  # --- параллельные PUT ------------------------------------------------------

  def test_readers_see_only_complete_versions_during_concurrent_puts_to_the_same_key
    size = CHUNK * 4 + 13
    versions = ("A".."H").map { |c| c.b * size }
    @store.put("hot", StringIO.new(versions.first))

    problems = Queue.new
    reads = Queue.new
    done = false

    writers = 4.times.map do |w|
      Thread.new do
        2.times do
          versions.each_with_index do |version, i|
            next unless i % 4 == w

            result = @store.put("hot", SlowInput.new(version))
            expected = { "key" => "hot", "sha256" => Digest::SHA256.hexdigest(version), "size" => size }
            problems << "PUT reported #{result.inspect}" unless result == expected
          end
        end
      rescue StandardError => e
        problems << e
      end
    end

    readers = 3.times.map do
      Thread.new do
        until done
          got_size, content = read_all(@store, "hot")
          unless got_size == content.bytesize && versions.include?(content)
            problems << "reader saw size=#{got_size} bytes=#{content.bytesize} head=#{content[0, 4].inspect} tail=#{content[-4..].inspect}"
          end
          reads << 1
        end
      rescue StandardError => e
        problems << e
      end
    end

    writers.each(&:join)
    done = true
    readers.each(&:join)

    assert_empty drain(problems)
    assert_operator reads.size, :>, 0, "readers must have raced the writers"
    final = read_all(@store, "hot").last
    assert_includes versions, final, "the final content is one complete version"
    assert_equal [["hot", size, Digest::SHA256.hexdigest(final)]],
                 @store.list.map { |m| m.values_at("key", "size", "sha256") }
    assert_empty tmp_entries
  end

  def test_concurrent_puts_to_different_keys_do_not_interfere
    payload_for = ->(t, i) { "#{t}-#{i}:".b + Random.new(t * 1000 + i).bytes(CHUNK + i) }
    key_for = ->(t, i) { "dir#{t % 3}/key-#{t}-#{i}" }
    problems = Queue.new

    threads = 8.times.map do |t|
      Thread.new do
        20.times do |i|
          payload = payload_for.call(t, i)
          result = @store.put(key_for.call(t, i), SlowInput.new(payload, pause: 0))
          expected = { "key" => key_for.call(t, i), "sha256" => Digest::SHA256.hexdigest(payload), "size" => payload.bytesize }
          problems << "PUT reported #{result.inspect}" unless result == expected
        end
      rescue StandardError => e
        problems << e
      end
    end
    threads.each(&:join)

    assert_empty drain(problems)
    8.times do |t|
      20.times do |i|
        assert_equal payload_for.call(t, i), File.binread(File.join(@data_dir, key_for.call(t, i))), key_for.call(t, i)
      end
    end
    assert_equal 160, @store.list.length
    assert_empty tmp_entries
  end

  # --- уборка временных файлов -----------------------------------------------

  def test_interrupted_body_leaves_no_temp_file_and_keeps_the_previous_version
    @store.put("k", StringIO.new("previous"))
    assert_raises(IOError) { @store.put("k", BrokenInput.new("x" * (CHUNK + 1))) }

    assert_empty tmp_entries
    assert_equal "previous", File.binread(File.join(@data_dir, "k"))
    assert_equal [["k", 8, Digest::SHA256.hexdigest("previous")]],
                 @store.list.map { |m| m.values_at("key", "size", "sha256") }
  end

  def test_interrupted_body_for_a_new_key_leaves_nothing_on_disk
    assert_raises(IOError) { @store.put("dir/new", BrokenInput.new("partial")) }

    assert_empty tmp_entries
    refute File.exist?(File.join(@data_dir, "dir")), "no directories are created for a blob that never arrived"
    assert_raises(Syncbox::Store::NotFound) { @store.open("dir/new") }
    assert_equal [], @store.list
  end

  def test_failed_rename_leaves_no_temp_file_and_keeps_existing_files
    @store.put("dir/child", StringIO.new("x"))
    assert_raises(Syncbox::Store::InvalidKey) { @store.put("dir", StringIO.new("y")) }
    assert_raises(Syncbox::Store::InvalidKey) { @store.put("dir/child/grandchild", StringIO.new("z")) }

    assert_empty tmp_entries
    assert_equal "x", File.binread(File.join(@data_dir, "dir", "child"))
  end

  def test_stale_temp_files_from_a_previous_process_are_removed_on_startup
    FileUtils.mkdir_p(@tmp_dir)
    stale = File.join(@tmp_dir, "#{'ab' * 16}#{Syncbox::Store::TMP_SUFFIX}")
    File.binwrite(stale, "half-written")
    foreign = File.join(@tmp_dir, "not-ours")
    File.binwrite(foreign, "keep")
    @store.put("k", StringIO.new("x"))

    store = Syncbox::Store.new(@data_dir)
    refute File.exist?(stale), "a leftover temp file is swept when the store starts"
    assert File.exist?(foreign), "only syncbox temp files are swept"
    assert_equal ["k"], store.list.map { |m| m["key"] }
  end

  def test_remove_stale_tmp_files_reports_how_many_were_removed_and_tolerates_absent_dir
    assert_equal 0, @store.remove_stale_tmp_files
    FileUtils.mkdir_p(@tmp_dir)
    2.times { |i| File.binwrite(File.join(@tmp_dir, "#{i}#{Syncbox::Store::TMP_SUFFIX}"), "x") }
    assert_equal 2, @store.remove_stale_tmp_files
    assert_empty tmp_entries

    store = Syncbox::Store.new(File.join(@data_dir, "not-yet"))
    refute File.exist?(File.join(@data_dir, "not-yet")), "the startup sweep creates nothing"
    assert_equal 0, store.remove_stale_tmp_files
  end
end
