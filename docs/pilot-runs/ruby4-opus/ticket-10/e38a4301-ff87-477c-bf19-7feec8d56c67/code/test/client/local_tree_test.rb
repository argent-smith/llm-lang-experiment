# frozen_string_literal: true

require "test_helper"
require "digest"

class LocalTreeTest < Minitest::Test
  LocalTree = Syncbox::Client::LocalTree

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_keys_are_relative_posix_paths_sorted
    write("b.txt", "b")
    write("a/z.txt", "z")
    write("a/b/c.bin", "c")
    write("a b/✓ #1%?.txt", "odd")
    write(".hidden", "h")
    Dir.mkdir(File.join(@dir, "empty"))

    files = LocalTree.new(@dir).files

    assert_equal [".hidden", "a b/✓ #1%?.txt", "a/b/c.bin", "a/z.txt", "b.txt"], files.map(&:key)
    assert_equal File.join(@dir, "a/b/c.bin"), files.find { |file| file.key == "a/b/c.bin" }.path
    files.each { |file| assert_equal Encoding::UTF_8, file.key.encoding }
  end

  def test_empty_directory_has_no_files
    assert_equal [], LocalTree.new(@dir).files
  end

  def test_the_clients_state_directory_is_left_out_silently
    write(".syncbox/state.json", "{}")
    write("a/.syncbox/x", "x")
    write(".syncbox-other", "o")
    skipped = []

    files = LocalTree.new(@dir).files { |key, reason| skipped << [key, reason] }

    assert_equal [".syncbox-other", "a/.syncbox/x"], files.map(&:key)
    assert_equal [], skipped
  end

  def test_size_and_sha256
    content = Random.new(3).bytes(3 * LocalTree::CHUNK_SIZE + 5)
    write("data.bin", content)
    write("empty", "")
    files = LocalTree.new(@dir).files.to_h { |file| [file.key, file] }

    assert_equal content.bytesize, files["data.bin"].size
    assert_equal Digest::SHA256.hexdigest(content), files["data.bin"].sha256
    assert_equal 0, files["empty"].size
    assert_equal Digest::SHA256.hexdigest(""), files["empty"].sha256
  end

  def test_symlinks_and_special_files_are_skipped_and_reported
    write("real/file", "x")
    File.symlink("real/file", File.join(@dir, "file-link"))
    File.symlink("real", File.join(@dir, "dir-link"))
    File.symlink("/etc/passwd", File.join(@dir, "real", "outside"))
    File.symlink("missing", File.join(@dir, "dangling"))
    File.mkfifo(File.join(@dir, "fifo"))
    skipped = []

    files = LocalTree.new(@dir).files { |key, reason| skipped << [key, reason] }

    assert_equal %w[real/file], files.map(&:key)
    assert_equal [["dangling", "symbolic link"], ["dir-link", "symbolic link"], ["fifo", "not a regular file"],
                  ["file-link", "symbolic link"], ["real/outside", "symbolic link"]], skipped.sort
  end

  def test_deeply_nested_directories
    key = "#{'d/' * 300}f"
    write(key, "x")

    assert_equal [key], LocalTree.new(@dir).files.map(&:key)
  end

  def test_file_name_that_is_not_utf8_cannot_be_a_key
    write("ok", "x")
    write("sub/\xFF\xFE".b, "x")

    error = assert_raises(Syncbox::Client::Error) { LocalTree.new(@dir).files }
    assert_match(%r{not valid UTF-8.*sub/}, error.message)
  end

  def test_unreadable_directory_is_an_error
    skip "root ignores permission bits" if Process.uid.zero?
    write("locked/secret", "x")
    File.chmod(0o000, File.join(@dir, "locked"))

    error = assert_raises(Syncbox::Client::Error) { LocalTree.new(@dir).files }
    assert_equal "cannot read directory locked: Permission denied", error.message
  ensure
    File.chmod(0o755, File.join(@dir, "locked"))
  end

  private

  def write(key, content)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
