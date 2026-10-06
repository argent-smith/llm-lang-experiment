# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "socket"

class ClientLocalTreeTest < Minitest::Test
  include TestHelpers

  LocalTree = Syncbox::Client::LocalTree

  def scan(dir, &on_warning)
    LocalTree.scan(dir, &on_warning)
  end

  def test_regular_files_become_keys_relative_to_the_directory_sorted_by_key
    with_tmpdir do |dir|
      write(dir, "docs/readme.txt", "hello")
      write(dir, "docs/img/logo.png", "\x89PNG".b)
      write(dir, "z.txt", "z")
      write(dir, "a.txt", "")

      files = scan(dir)
      assert_equal ["a.txt", "docs/img/logo.png", "docs/readme.txt", "z.txt"], files.map(&:key)

      readme = files.find { |f| f.key == "docs/readme.txt" }
      assert_equal File.join(dir, "docs/readme.txt"), readme.path
      assert_equal 5, readme.size
      assert_equal Digest::SHA256.hexdigest("hello"), readme.sha256

      empty = files.find { |f| f.key == "a.txt" }
      assert_equal 0, empty.size
      assert_equal Digest::SHA256.hexdigest(""), empty.sha256
    end
  end

  def test_hidden_files_spaces_and_unicode_names_are_included
    with_tmpdir do |dir|
      write(dir, ".hidden", "h")
      write(dir, ".git/config", "c")
      write(dir, "sp ace/ü ✓.txt", "u")

      assert_equal [".git/config", ".hidden", "sp ace/ü ✓.txt"], scan(dir).map(&:key)
      scan(dir).each { |f| assert_equal Encoding::UTF_8, f.key.encoding }
    end
  end

  def test_empty_directories_contribute_nothing
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "empty/nested"))
      assert_equal [], scan(dir)
    end
  end

  def test_relative_and_trailing_slash_directories_are_expanded
    with_tmpdir do |dir|
      write(dir, "f", "x")
      Dir.chdir(dir) do
        assert_equal ["f"], scan(".").map(&:key)
        assert_equal File.join(dir, "f"), scan(".").first.path
      end
      assert_equal ["f"], scan("#{dir}/").map(&:key)
    end
  end

  def test_symlinks_are_skipped_with_a_warning_and_never_followed
    with_tmpdir do |dir|
      write(dir, "real.txt", "real")
      File.symlink(File.join(dir, "real.txt"), File.join(dir, "file-link"))
      File.symlink("/etc", File.join(dir, "dir-link"))
      File.symlink("nowhere", File.join(dir, "dangling"))
      File.symlink(dir, File.join(dir, "loop"))

      warnings = []
      files = scan(dir) { |w| warnings << w }
      assert_equal ["real.txt"], files.map(&:key)
      assert_equal ["skipping dangling: symbolic links are not uploaded",
                    "skipping dir-link: symbolic links are not uploaded",
                    "skipping file-link: symbolic links are not uploaded",
                    "skipping loop: symbolic links are not uploaded"], warnings.sort
    end
  end

  def test_special_files_are_skipped_with_a_warning
    with_tmpdir do |dir|
      write(dir, "f", "x")
      UNIXServer.new(File.join(dir, "sock")).close
      begin
        File.mkfifo(File.join(dir, "fifo"))
      rescue NotImplementedError, SystemCallError
        nil
      end

      warnings = []
      assert_equal ["f"], scan(dir) { |w| warnings << w }.map(&:key)
      assert_includes warnings, "skipping sock: not a regular file (socket)"
      assert_includes warnings, "skipping fifo: not a regular file (fifo)" if File.exist?(File.join(dir, "fifo"))
    end
  end

  def test_file_name_that_is_not_valid_utf8_is_an_error
    with_tmpdir do |dir|
      File.write(File.join(dir, "bad-\xFF-name".b), "x")
      error = assert_raises(LocalTree::Error) { scan(dir) }
      assert_match(/not valid UTF-8/, error.message)
      assert_match(/bad-/, error.message)
    end
  end

  def test_missing_or_non_directory_path_is_an_error
    with_tmpdir do |dir|
      error = assert_raises(LocalTree::Error) { scan(File.join(dir, "nope")) }
      assert_match(/not a directory/, error.message)
      write(dir, "file", "x")
      assert_raises(LocalTree::Error) { scan(File.join(dir, "file")) }
    end
  end

  def test_unreadable_file_is_an_error_naming_the_key
    skip "root can read anything" if Process.uid.zero?

    with_tmpdir do |dir|
      write(dir, "sub/secret.txt", "x")
      File.chmod(0o000, File.join(dir, "sub/secret.txt"))
      begin
        error = assert_raises(LocalTree::Error) { scan(dir) }
        assert_match(/cannot read sub\/secret\.txt: Permission denied/, error.message)
      ensure
        File.chmod(0o600, File.join(dir, "sub/secret.txt"))
      end
    end
  end

  def test_lookup_returns_the_file_under_a_key_or_nil
    with_tmpdir do |dir|
      write(dir, "docs/readme.txt", "hello")
      File.chmod(0o640, File.join(dir, "docs/readme.txt"))
      tree = LocalTree.new(dir)

      file = tree.lookup("docs/readme.txt")
      assert_equal "docs/readme.txt", file.key
      assert_equal File.join(dir, "docs/readme.txt"), file.path
      assert_equal [5, Digest::SHA256.hexdigest("hello"), 0o640], [file.size, file.sha256, file.mode]

      assert_nil tree.lookup("docs/missing.txt")
      assert_nil tree.lookup("no/such/dir/file")
      assert_equal File.join(dir, "no/such/dir/file"), tree.path_for("no/such/dir/file")
    end
  end

  def test_lookup_refuses_entries_that_are_not_regular_files
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "d"))
      File.symlink("/etc/hostname", File.join(dir, "link"))
      UNIXServer.new(File.join(dir, "sock")).close
      tree = LocalTree.new(dir)

      assert_match(/\Ad: a directory is in the way of the file/, assert_raises(LocalTree::Error) { tree.lookup("d") }.message)
      assert_match(/\Alink: a symbolic link is in the way of the file/, assert_raises(LocalTree::Error) { tree.lookup("link") }.message)
      assert_match(/\Asock: a socket is in the way of the file/, assert_raises(LocalTree::Error) { tree.lookup("sock") }.message)
    end
  end

  def test_path_for_refuses_keys_that_could_leave_the_directory
    with_tmpdir do |dir|
      tree = LocalTree.new(dir)
      {
        "../x" => /\.\. segment/, "a/../../x" => /\.\. segment/, "./x" => /\. or \.\. segment/,
        "/etc/passwd" => /absolute path/, "a//b" => /empty path segment/, "a/" => /empty path segment/,
        "" => /empty path segment/, "a\0b" => /NUL byte/
      }.each do |key, reason|
        error = assert_raises(LocalTree::Error, key.inspect) { tree.path_for(key) }
        assert_match(/\Arefusing key #{Regexp.escape(key.inspect)} from the server: /, error.message)
        assert_match(reason, error.message)
      end
      error = assert_raises(LocalTree::Error) { tree.path_for("bad-\xFF".b) }
      assert_match(/not valid UTF-8/, error.message)

      # Ordinary names that merely contain dots are fine.
      assert_equal File.join(dir, "a..b/.hidden/..."), tree.path_for("a..b/.hidden/...")
    end
  end

  def test_path_for_never_resolves_through_a_symlinked_or_non_directory_ancestor
    with_tmpdir do |dir|
      outside = Dir.mktmpdir("syncbox-outside-")
      begin
        File.symlink(outside, File.join(dir, "dirlink"))
        FileUtils.mkdir_p(File.join(dir, "real/sub"))
        File.symlink("../dirlink", File.join(dir, "real/sub/link2"))
        write(dir, "file", "x")
        tree = LocalTree.new(dir)

        error = assert_raises(LocalTree::Error) { tree.path_for("dirlink/a/b") }
        assert_match(%r{\Adirlink/a/b: a symbolic link is in the way \(dirlink\); links are not followed}, error.message)
        error = assert_raises(LocalTree::Error) { tree.path_for("real/sub/link2/x") }
        assert_match(%r{a symbolic link is in the way \(real/sub/link2\)}, error.message)
        error = assert_raises(LocalTree::Error) { tree.path_for("file/x") }
        assert_match(%r{\Afile/x: file is in the way and is not a directory}, error.message)
        assert_raises(LocalTree::Error) { tree.lookup("dirlink/a/b") }

        assert_equal File.join(dir, "real/sub/new.txt"), tree.path_for("real/sub/new.txt")
        assert_equal [], Dir.children(outside)
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end

  private

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
