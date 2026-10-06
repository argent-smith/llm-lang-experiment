# frozen_string_literal: true

require "test_helper"

# Обход локального каталога: key — относительный POSIX-путь, сортировка,
# пропуск не-файлов.
class ClientLocalTreeTest < Minitest::Test
  LocalTree = Syncbox::Client::LocalTree

  def setup
    @dir = Dir.mktmpdir("syncbox-tree")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def write(rel, content = rel)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def scan(dir = @dir)
    skipped = []
    entries = LocalTree.scan(dir) { |rel, reason| skipped << [rel, reason] }
    [entries, skipped]
  end

  def test_lists_regular_files_recursively_with_posix_keys_sorted
    %w[b.txt a.txt docs/readme.txt docs/sub/deep/x.bin .hidden/.dotfile empty].each { |rel| write(rel) }
    File.binwrite(File.join(@dir, "empty"), "")
    FileUtils.mkdir_p(File.join(@dir, "empty-dir", "nested-empty"))

    entries, skipped = scan
    assert_equal [".hidden/.dotfile", "a.txt", "b.txt", "docs/readme.txt", "docs/sub/deep/x.bin", "empty"], entries.map(&:key)
    entries.each do |entry|
      assert_equal File.join(@dir, entry.key), entry.path
      assert File.file?(entry.path)
    end
    assert_empty skipped
  end

  def test_keys_are_utf8_and_keep_spaces_and_unicode
    write("каталог/файл с пробелом.txt")
    write("ü+%?#.txt")
    entries, = scan
    assert_equal ["ü+%?#.txt", "каталог/файл с пробелом.txt"], entries.map(&:key)
    entries.each { |entry| assert_equal Encoding::UTF_8, entry.key.encoding }
  end

  def test_accepts_relative_dir
    write("x")
    Dir.chdir(File.dirname(@dir)) do
      entries, = scan(File.basename(@dir))
      assert_equal ["x"], entries.map(&:key)
      assert_equal File.join(@dir, "x"), entries.first.path
    end
  end

  def test_symlinks_to_files_are_included_and_symlinks_to_directories_are_not_followed
    target = write("real/target.txt", "target")
    File.symlink(target, File.join(@dir, "link.txt"))
    File.symlink(File.join(@dir, "real"), File.join(@dir, "dir-link"))
    File.symlink(File.join(@dir, "missing"), File.join(@dir, "broken"))

    entries, skipped = scan
    assert_equal ["link.txt", "real/target.txt"], entries.map(&:key)
    assert_equal "target", File.binread(entries.first.path)
    assert_equal ["broken", "dir-link"], skipped.map(&:first).sort
    assert_match(/broken symlink/, skipped.assoc("broken").last)
    assert_match(/symlink to a directory is not followed/, skipped.assoc("dir-link").last)
  end

  def test_non_regular_files_are_skipped_with_a_reason
    write("ok")
    File.mkfifo(File.join(@dir, "pipe"))
    entries, skipped = scan
    assert_equal ["ok"], entries.map(&:key)
    assert_equal [["pipe", "not a regular file (fifo)"]], skipped
  end

  def test_empty_directory_yields_nothing
    entries, skipped = scan
    assert_empty entries
    assert_empty skipped
  end

  def test_missing_or_non_directory_path_is_an_error
    error = assert_raises(Syncbox::Client::Error) { LocalTree.scan(File.join(@dir, "nope")) }
    assert_match(/directory not found: .*nope/, error.message)
    file = write("file")
    error = assert_raises(Syncbox::Client::Error) { LocalTree.scan(file) }
    assert_match(/not a directory: .*file/, error.message)
  end

  def test_file_name_that_is_not_valid_utf8_is_an_error
    write("ok")
    File.binwrite(File.join(@dir, "bad-\xff.txt".b), "x")
    error = assert_raises(Syncbox::Client::Error) { LocalTree.scan(@dir) }
    assert_match(/cannot use "bad-\\xFF\.txt" as a blob key: file name is not valid UTF-8/, error.message)
  end
end
