# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "rack/lint"
require "rack/test"

# Lets a test run code in place of Dir.mkdir on the current thread, to replay
# interleavings of concurrent requests deterministically.
module MkdirInterleaving
  def mkdir(path, *rest)
    hook = Thread.current[:syncbox_mkdir_hook]
    return super unless hook

    Thread.current[:syncbox_mkdir_hook] = nil
    begin
      hook.call(path) { super }
    ensure
      Thread.current[:syncbox_mkdir_hook] = hook
    end
  end
end
Dir.singleton_class.prepend(MkdirInterleaving)

# DELETE /blobs/{key}: 204 when a blob was removed, 404 when there is none,
# 400 for a key that cannot name a blob.
class DeleteBlobTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @root = Dir.mktmpdir
    @data_dir = File.join(@root, "data")
    @blobs_dir = File.join(@data_dir, "blobs")
    Dir.mkdir(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def app
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080)
    Rack::Lint.new(Syncbox::Server::Runner.build_app(config))
  end

  def test_delete_existing_blob_returns_204_without_body
    put "/blobs/docs/readme.txt", "hello"
    delete "/blobs/docs/readme.txt"
    assert_equal 204, last_response.status
    assert_empty last_response.body
    assert_nil last_response.headers["content-type"]
  end

  def test_deleted_blob_is_gone_from_get_and_list
    put "/blobs/docs/readme.txt", "hello"
    put "/blobs/docs/other.txt", "other"
    put "/blobs/top", "top"

    delete "/blobs/docs/readme.txt"
    assert_equal 204, last_response.status

    get "/blobs/docs/readme.txt"
    assert_equal 404, last_response.status
    assert_equal %w[docs/other.txt top], listing
    get "/blobs/docs/other.txt"
    assert_equal "other", last_response.body
  end

  def test_delete_missing_blob_returns_404
    delete "/blobs/missing"
    assert_equal 404, last_response.status

    put "/blobs/dir/file", "x"
    %w[dir/missing missing/file dir/file/below dir].each do |key|
      delete "/blobs/#{key}"
      assert_equal 404, last_response.status, "key #{key.inspect}"
    end
    assert_equal ["dir/file"], listing
  end

  def test_second_delete_returns_404
    put "/blobs/a", "x"
    delete "/blobs/a"
    assert_equal 204, last_response.status
    delete "/blobs/a"
    assert_equal 404, last_response.status
  end

  def test_blob_can_be_stored_again_after_delete
    put "/blobs/a", "first"
    delete "/blobs/a"
    put "/blobs/a", "second"
    assert_equal 201, last_response.status
    get "/blobs/a"
    assert_equal "second", last_response.body
  end

  def test_delete_prunes_directories_left_empty
    put "/blobs/a/b/c/d", "x"
    put "/blobs/a/keep", "y"
    delete "/blobs/a/b/c/d"
    assert_equal 204, last_response.status
    assert_equal ["keep"], Dir.children(File.join(@blobs_dir, "a"))

    # The former directory path is free to be a blob now.
    put "/blobs/a/b", "z"
    assert_equal 201, last_response.status
    delete "/blobs/a/keep"
    delete "/blobs/a/b"
    put "/blobs/a", "file"
    assert_equal 201, last_response.status
    assert_equal ["a"], listing
  end

  def test_delete_decodes_percent_encoded_key
    put "/blobs/a%20b/%C3%A9t%C3%A9+x%3F", "x"
    delete "/blobs/a%20b/%C3%A9t%C3%A9+x%3F"
    assert_equal 204, last_response.status
    assert_equal [], listing
  end

  def test_delete_does_not_touch_symlinks_or_their_targets
    outside = File.join(@root, "outside")
    Dir.mkdir(outside)
    File.write(File.join(outside, "victim"), "keep me")
    FileUtils.mkdir_p(@blobs_dir)
    File.symlink(outside, File.join(@blobs_dir, "dirlink"))
    File.symlink(File.join(outside, "victim"), File.join(@blobs_dir, "filelink"))

    %w[dirlink/victim filelink dirlink].each do |key|
      delete "/blobs/#{key}"
      assert_equal 404, last_response.status, "key #{key.inspect}"
    end
    assert_equal "keep me", File.read(File.join(outside, "victim"))
    assert File.symlink?(File.join(@blobs_dir, "filelink"))
    assert File.symlink?(File.join(@blobs_dir, "dirlink"))
  end

  def test_delete_rejects_invalid_keys_with_400
    put "/blobs/x", "x"
    invalid = [
      "", "..", "a/../x", "%2e%2e/x", "..%2Fx", "/etc/passwd", "%2Fetc%2Fpasswd",
      ".", "./x", "a//x", "x/", "%00", "%FF", "%ED%A0%80", "%", "%zz"
    ]
    invalid.each do |key|
      delete_raw "/blobs/#{key}".b
      assert_equal 400, last_response.status, "key #{key.inspect}"
    end
    assert_equal ["x"], listing
  end

  def test_delete_garbage_keys_never_leaves_contract
    rng = Random.new(20_261_003)
    alphabet = ["a", "0", ".", "..", "/", "%", "%2F", "%2e", "%00", "%FF", "%C3%A9", "%ED%A0%80",
                " ", "+", "\\", "\xFF".b, "x" * 300]
    300.times do
      key = Array.new(rng.rand(0..8)) { alphabet.sample(random: rng) }.join.b
      put_raw "/blobs/#{key}".b, "x"
      delete_raw "/blobs/#{key}".b
      assert_includes [204, 400, 404], last_response.status, "key #{key.inspect}"
    end
    assert_equal [], listing
    assert_equal [], Dir.children(@data_dir) - %w[blobs tmp]
  end

  def test_concurrent_put_and_delete_under_shared_directories
    store = Syncbox::Server::Store.new(@data_dir)
    threads = Array.new(4) do |t|
      Thread.new do
        200.times do |i|
          key = "shared/dir/#{t}-#{i % 2}"
          store.put(key, StringIO.new("x"))
          store.delete(key)
        end
      end
    end
    threads.each(&:join)
    assert_equal [], store.list
  end

  # Another put creates the directory, so mkdir fails with EEXIST, and a
  # delete prunes it again before put looks: put must retry, not answer 400.
  def test_put_retries_when_directory_is_pruned_right_after_eexist
    shared = File.join(@blobs_dir, "shared")
    races = 0
    hook = lambda do |path, &mkdir|
      next mkdir.call unless path == shared && races < 3

      races += 1
      raise Errno::EEXIST, path
    end
    with_mkdir_hook(hook) { put "/blobs/shared/dir/file", "x" }

    assert_equal 3, races
    assert_equal 201, last_response.status
    assert_equal ["shared/dir/file"], listing
  end

  # Same, but the directory is already back when put looks again.
  def test_put_accepts_directory_recreated_right_after_eexist
    shared = File.join(@blobs_dir, "shared")
    hook = lambda do |path, &mkdir|
      next mkdir.call unless path == shared

      Dir.mkdir(path)
      raise Errno::EEXIST, path
    end
    with_mkdir_hook(hook) { put "/blobs/shared/file", "x" }

    assert_equal 201, last_response.status
    assert_equal ["shared/file"], listing
  end

  def test_put_still_rejects_non_directory_in_the_way_with_400
    put "/blobs/a", "file"
    File.symlink(File.join(@root, "nowhere"), File.join(@blobs_dir, "dangling"))
    %w[a/b a/b/c dangling/x].each do |key|
      put "/blobs/#{key}", "x"
      assert_equal 400, last_response.status, "key #{key.inspect}"
    end
    assert_equal ["a"], listing
  end

  def test_concurrent_http_put_and_delete_under_shared_directories
    statuses = Queue.new
    threads = Array.new(8) do |t|
      Thread.new do
        session = Rack::Test::Session.new(app)
        300.times do |i|
          key = "shared/dir/#{t}-#{i % 2}"
          session.put "/blobs/#{key}", "x"
          statuses << [:put, key, session.last_response.status]
          session.delete "/blobs/#{key}"
          statuses << [:delete, key, session.last_response.status]
        end
      end
    end
    threads.each(&:join)

    results = Array.new(statuses.size) { statuses.pop }
    assert_equal [], results.reject { |op, _, status| status == (op == :put ? 201 : 204) }
    assert_equal [], listing
  end

  private

  def with_mkdir_hook(hook)
    Thread.current[:syncbox_mkdir_hook] = hook
    yield
  ensure
    Thread.current[:syncbox_mkdir_hook] = nil
  end

  def listing
    get "/blobs"
    assert_equal 200, last_response.status
    JSON.parse(last_response.body).map { |e| e["key"] }
  end

  # Send requests with an arbitrary raw path, bypassing URI parsing in rack-test.
  def put_raw(path, body = "")
    put "/blobs/placeholder", body, "PATH_INFO" => path
  end

  def delete_raw(path)
    delete "/blobs/placeholder", {}, "PATH_INFO" => path
  end
end
