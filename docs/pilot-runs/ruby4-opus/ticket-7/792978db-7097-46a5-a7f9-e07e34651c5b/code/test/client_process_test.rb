# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "support/server_process"

# Runs bin/syncbox as a separate process, the way run-client does inside the
# container, against a real server (bin/syncbox-server) over HTTP.
class ClientProcessTest < Minitest::Test
  include ServerProcess

  CLIENT_BIN = File.expand_path("../bin/syncbox", __dir__)

  def setup
    @tmp = Dir.mktmpdir
    @port = free_port
    @dir = File.join(@tmp, "local")
    Dir.mkdir(@dir)
  end

  def teardown
    stop_server
    FileUtils.rm_rf(@tmp)
  end

  def test_push_uploads_the_directory_byte_for_byte
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    files = {
      "a.txt" => "hello\n", "empty" => "", "docs/data.bin" => Random.new(7).bytes(1_000_000),
      "docs/deep/er/x" => "x", "with space/100% ✓ #1?.txt" => "odd name", "a\\b" => "backslash"
    }
    files.each { |key, content| write(key, content) }

    out, err, status = client("push", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "", err
    assert_equal files.keys.sort.map { |key| "uploaded #{key}\n" }.join + "push: 6 uploaded, 0 up to date\n", out
    assert_equal files.keys.sort, stored.keys
    files.each do |key, content|
      assert_equal Digest::SHA256.hexdigest(content), stored[key]["sha256"], key
      assert_equal content, get(Syncbox::Client::Remote.new(URI(url)).blob_path(key)).body.b, key
    end
  end

  def test_push_skips_unchanged_files_and_uploads_changed_ones
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("same", "same")
    write("edited", "before")
    write("dir/resized", "short")
    assert_predicate client("push", @dir, "--server", url)[2], :success?
    modified_at = stored.transform_values { |blob| blob["modified_at"] }

    write("edited", "after!") # same size, other content
    write("dir/resized", "much longer now")
    write("dir/new", "new")
    out, err, status = client("push", @dir, "--server", url)

    assert_predicate status, :success?, err
    assert_equal "uploaded dir/new\nuploaded dir/resized\nuploaded edited\npush: 3 uploaded, 1 up to date\n", out
    assert_equal modified_at["same"], stored["same"]["modified_at"], "an unchanged file must not be uploaded again"
    assert_equal Digest::SHA256.hexdigest("after!"), stored["edited"]["sha256"]
    assert_equal Digest::SHA256.hexdigest("much longer now"), stored["dir/resized"]["sha256"]

    out, = client("push", @dir, "--server", url)

    assert_equal "push: 0 uploaded, 4 up to date\n", out
  end

  def test_push_leaves_blobs_without_a_local_file_alone
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    Net::HTTP.start("127.0.0.1", @port) { |http| http.put("/blobs/server-only", "kept") }
    write("local", "x")

    assert_predicate client("push", @dir, "--server", url)[2], :success?
    assert_equal %w[local server-only], stored.keys
  end

  def test_server_from_environment_and_base_url_with_trailing_slash
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("f", "x")

    out, err, status = client("push", @dir, env: { "SYNCBOX_SERVER" => "#{url}/" })

    assert_predicate status, :success?, err
    assert_equal "uploaded f\npush: 1 uploaded, 0 up to date\n", out
    assert_equal %w[f], stored.keys
  end

  def test_key_rejected_by_the_server_fails_the_push
    start_server("--data-dir", File.join(@tmp, "data"), "--port", @port.to_s)
    write("..\\escape", "x") # a valid local name, but a traversal key for the server

    out, err, status = client("push", @dir, "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(/\Asyncbox: cannot upload \.\.\\escape: server answered 400 invalid key\n\z/, err)
    assert_equal({}, stored)
  end

  def test_unreachable_server_fails_fast_with_a_message
    write("f", "x")
    started = Time.now

    out, err, status = client("push", @dir, "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_match(%r{\Asyncbox: cannot list blobs: server #{Regexp.escape(url)} is unreachable: .*refused.*\n\z}, err)
    assert_operator Time.now - started, :<, 15
  end

  def test_missing_directory_fails
    out, err, status = client("push", File.join(@tmp, "missing"), "--server", url)

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_equal "syncbox: not a directory: #{File.join(@tmp, 'missing')}\n", err
  end

  def test_other_commands_are_not_implemented_yet
    %w[pull status sync].each do |command|
      out, err, status = client(command, @dir, "--server", url)

      assert_equal 1, status.exitstatus, command
      assert_equal "", out
      assert_match(/\Asyncbox: command "#{command}" is not implemented yet/, err)
    end
  end

  def test_usage_errors
    [["push", @dir], ["push"], ["fetch", @dir, "--server", url], ["push", @dir, "--server", "nope"]].each do |argv|
      out, err, status = client(*argv)

      assert_equal 2, status.exitstatus, argv.inspect
      assert_equal "", out
      assert_match(/\Asyncbox: .*\nUsage: syncbox <push\|pull\|status\|sync> <dir> --server <url>\n\z/, err)
    end
  end

  def test_help
    out, _, status = client("--help")

    assert_predicate status, :success?
    assert_match(/\AUsage: syncbox/, out)
  end

  private

  def url
    "http://127.0.0.1:#{@port}"
  end

  def client(*args, env: {})
    Open3.capture3(clean_env.merge(env), CLIENT_BIN, *args)
  end

  def write(key, content)
    path = File.join(@dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  # The server's blob list: {key => metadata}.
  def stored
    JSON.parse(get("/blobs").body).to_h { |blob| [blob["key"], blob] }
  end
end
