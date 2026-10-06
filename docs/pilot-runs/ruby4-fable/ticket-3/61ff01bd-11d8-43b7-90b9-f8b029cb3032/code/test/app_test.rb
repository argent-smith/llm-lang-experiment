# frozen_string_literal: true

require "test_helper"
require "digest"
require "time"

class AppTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  OCTET = { "CONTENT_TYPE" => "application/octet-stream" }.freeze

  def setup
    @data_dir = Dir.mktmpdir("syncbox-app-test-")
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && File.exist?(@data_dir)
  end

  def app
    config = Syncbox::Server::Config.new(data_dir: @data_dir)
    Syncbox::Server::App.new(config)
  end

  def body_json
    JSON.parse(last_response.body)
  end

  # --- healthz / routing (ticket 1) ---------------------------------------

  def test_healthz_returns_200
    get "/healthz"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.headers["content-type"]
    assert_equal({ "status" => "ok" }, body_json)
  end

  def test_healthz_supports_head
    head "/healthz"
    assert_equal 200, last_response.status
  end

  def test_healthz_rejects_other_methods
    post "/healthz"
    assert_equal 405, last_response.status
    assert_equal "GET, HEAD", last_response.headers["allow"]
  end

  def test_unknown_path_returns_404
    get "/does-not-exist"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not found" }, body_json)
  end

  def test_healthz_with_trailing_segment_is_not_healthz
    get "/healthz/extra"
    assert_equal 404, last_response.status
  end

  def test_blobs_lookalike_paths_are_not_blob_routes
    get "/blobsx"
    assert_equal 404, last_response.status
    get "/blobs-list"
    assert_equal 404, last_response.status
  end

  # --- GET /blobs ---------------------------------------------------------

  def test_list_blobs_is_200_with_empty_array_on_fresh_store
    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.headers["content-type"]
    assert_equal [], body_json
  end

  def test_list_blobs_returns_metadata_for_every_stored_blob
    put "/blobs/docs/readme.txt", "hello", OCTET
    put "/blobs/0", "", OCTET
    get "/blobs"
    assert_equal 200, last_response.status

    list = body_json
    assert_equal %w[0 docs/readme.txt], list.map { |m| m["key"] }
    readme = list.last
    assert_equal 5, readme["size"]
    assert_equal Digest::SHA256.hexdigest("hello"), readme["sha256"]
    assert_match(/\A[0-9a-f]{64}\z/, readme["sha256"])
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/, readme["modified_at"])
    assert_equal %w[key modified_at sha256 size], readme.keys.sort
  end

  def test_list_blobs_rejects_other_methods
    post "/blobs"
    assert_equal 405, last_response.status
    assert_equal "GET, HEAD", last_response.headers["allow"]
  end

  def test_list_blobs_reports_nested_keys_as_posix_paths
    put "/blobs/top.txt", "t", OCTET
    put "/blobs/docs/readme.txt", "r", OCTET
    put "/blobs/docs/img/logo.png", "l", OCTET
    put "/blobs/a/b/c/d/e", "deep", OCTET
    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal %w[a/b/c/d/e docs/img/logo.png docs/readme.txt top.txt], body_json.map { |m| m["key"] }
  end

  def test_list_blobs_includes_blobs_that_appeared_on_disk_outside_the_api
    root = File.join(@data_dir, "blobs")
    FileUtils.mkdir_p(File.join(root, "ext", "sub"))
    File.binwrite(File.join(root, "ext", "sub", "file.bin"), "\x00\x01\x02")
    File.write(File.join(root, "ext", "note"), "n")
    get "/blobs"
    assert_equal 200, last_response.status
    by_key = body_json.to_h { |m| [m["key"], m] }
    assert_equal %w[ext/note ext/sub/file.bin], by_key.keys.sort
    assert_equal 3, by_key["ext/sub/file.bin"]["size"]
    assert_equal Digest::SHA256.hexdigest("\x00\x01\x02".b), by_key["ext/sub/file.bin"]["sha256"]
  end

  def test_list_blobs_modified_at_is_the_file_mtime_in_utc
    put "/blobs/docs/readme.txt", "hello", OCTET
    path = File.join(@data_dir, "blobs", "docs", "readme.txt")
    past = Time.utc(2024, 2, 29, 12, 34, 56, 789_000)
    File.utime(past, past, path)

    get "/blobs"
    meta = body_json.fetch(0)
    assert_equal "2024-02-29T12:34:56.789Z", meta["modified_at"]
    assert_equal past, Time.iso8601(meta["modified_at"])
    assert_equal File.mtime(path).floor(3), Time.iso8601(meta["modified_at"])
  end

  def test_list_blobs_reflects_overwrite_in_size_sha256_and_modified_at
    put "/blobs/k", "one", OCTET
    past = Time.utc(2020, 1, 1)
    File.utime(past, past, File.join(@data_dir, "blobs", "k"))
    get "/blobs"
    before = body_json.fetch(0)
    assert_equal "2020-01-01T00:00:00.000Z", before["modified_at"]

    put "/blobs/k", "two-two", OCTET
    get "/blobs"
    assert_equal 1, body_json.size
    after = body_json.fetch(0)
    assert_equal 7, after["size"]
    assert_equal Digest::SHA256.hexdigest("two-two"), after["sha256"]
    assert_operator Time.iso8601(after["modified_at"]), :>, Time.iso8601(before["modified_at"])
  end

  def test_list_blobs_ignores_empty_directories_and_writes_in_progress
    FileUtils.mkdir_p(File.join(@data_dir, "blobs", "empty", "nested"))
    FileUtils.mkdir_p(File.join(@data_dir, "tmp"))
    File.write(File.join(@data_dir, "tmp", "put-deadbeef"), "half-written")
    put "/blobs/real", "r", OCTET
    get "/blobs"
    assert_equal ["real"], body_json.map { |m| m["key"] }
  end

  def test_list_blobs_keys_survive_json_round_trip
    keys = ["quote\"d", "back\\slash", "tab\tchar", "ümlaut/日本語.txt", "sp ace"]
    keys.each do |key|
      put "/blobs/#{escape_key(key)}", key, OCTET
      assert_equal 201, last_response.status, key.inspect
    end
    get "/blobs"
    assert_equal keys.sort, body_json.map { |m| m["key"] }
  end

  # Percent-encodes every byte outside the unreserved set (and "/"), the way a
  # client would put a key into a request path.
  def escape_key(key)
    key.b.gsub(%r{[^A-Za-z0-9_.\-~/]}) { |c| format("%%%02X", c.ord) }
  end

  # --- PUT /blobs/{key} ---------------------------------------------------

  def test_put_blob_is_201_with_key_sha_and_size
    put "/blobs/0", "payload", OCTET
    assert_equal 201, last_response.status
    assert_equal "application/json", last_response.headers["content-type"]
    assert_equal(
      { "key" => "0", "sha256" => Digest::SHA256.hexdigest("payload"), "size" => 7 },
      body_json
    )
  end

  def test_put_nested_key_creates_subdirectories_and_get_returns_bytes
    put "/blobs/docs/readme.txt", "hello world", OCTET
    assert_equal 201, last_response.status
    assert_equal(
      { "key" => "docs/readme.txt", "sha256" => Digest::SHA256.hexdigest("hello world"), "size" => 11 },
      body_json
    )
    assert File.file?(File.join(@data_dir, "blobs", "docs", "readme.txt"))

    get "/blobs/docs/readme.txt"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.headers["content-type"]
    assert_equal "hello world", last_response.body
  end

  def test_put_blob_without_body_is_201_with_empty_blob
    put "/blobs/0", nil, OCTET
    assert_equal 201, last_response.status
    assert_equal 0, body_json["size"]
    assert_equal Digest::SHA256.hexdigest(""), body_json["sha256"]
  end

  def test_put_blob_does_not_require_a_content_type
    put "/blobs/plain", "x"
    assert_equal 201, last_response.status
  end

  def test_put_blob_overwrites_and_get_returns_latest_bytes
    put "/blobs/k", "one", OCTET
    put "/blobs/k", "two", OCTET
    assert_equal 201, last_response.status
    get "/blobs/k"
    assert_equal 200, last_response.status
    assert_equal "two", last_response.body
  end

  def test_put_blob_decodes_percent_encoded_key
    put "/blobs/dir%2Fsp%20ace/%C3%BC.txt", "v", OCTET
    assert_equal 201, last_response.status
    assert_equal "dir/sp ace/ü.txt", body_json["key"]
    get "/blobs"
    assert_equal ["dir/sp ace/ü.txt"], body_json.map { |m| m["key"] }
  end

  def test_put_blob_keeps_plus_literal
    put "/blobs/a+b", "v", OCTET
    assert_equal 201, last_response.status
    assert_equal "a+b", body_json["key"]
  end

  def test_put_blob_with_traversal_key_is_400
    %w[/blobs/../x /blobs/a/../b /blobs/%2e%2e/x /blobs/..%2Fx /blobs/a/.. /blobs/./a].each do |path|
      put path, "v", OCTET
      assert_equal 400, last_response.status, path
      assert_equal "invalid key", body_json["error"], path
    end
    get "/blobs"
    assert_equal [], body_json
  end

  GARBAGE_KEYS = [
    "/blobs/", "/blobs//", "/blobs//abs", "/blobs/a/", "/blobs/a//b", "/blobs/%00", "/blobs/a%00b",
    "/blobs/%ED%A0%80", "/blobs/%FF", "/blobs/%C3", "/blobs/#{'x' * 256}", "/blobs/#{'x' * 300}/y",
    "/blobs/%2F", "/blobs/%2F%2F", "/blobs/.", "/blobs/..", "/blobs/%2e", "/blobs/%2e%2e"
  ].freeze

  def test_put_blob_with_garbage_key_is_400_and_never_5xx
    GARBAGE_KEYS.each do |path|
      put path, "v", OCTET
      assert_equal 400, last_response.status, path
    end
  end

  def test_get_and_delete_with_garbage_key_are_400_or_404_and_never_5xx
    GARBAGE_KEYS.each do |path|
      get path
      assert_includes [400, 404], last_response.status, "GET #{path}"
      delete path
      assert_includes [400, 404], last_response.status, "DELETE #{path}"
    end
  end

  def test_encoded_percent_sign_round_trips
    put "/blobs/100%25", "v", OCTET
    assert_equal 201, last_response.status
    assert_equal "100%", body_json["key"]
    get "/blobs/100%25"
    assert_equal 200, last_response.status
  end

  def test_put_blob_under_key_that_is_an_existing_file_is_400
    put "/blobs/a", "file", OCTET
    put "/blobs/a/b", "nested", OCTET
    assert_equal 400, last_response.status
    put "/blobs/a", "still a file", OCTET
    assert_equal 201, last_response.status
  end

  def test_put_blob_over_key_that_is_an_existing_directory_is_400
    put "/blobs/a/b", "nested", OCTET
    put "/blobs/a", "file", OCTET
    assert_equal 400, last_response.status
  end

  # --- GET / DELETE /blobs/{key} ------------------------------------------

  def test_get_blob_returns_bytes_as_octet_stream
    data = (0..255).map(&:chr).join.b
    put "/blobs/bin", data, OCTET
    get "/blobs/bin"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.headers["content-type"]
    assert_equal data.bytesize.to_s, last_response.headers["content-length"]
    assert_equal data, last_response.body.b
  end

  def test_get_missing_blob_is_404
    get "/blobs/missing"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not found" }, body_json)
  end

  def test_get_directory_key_is_404
    put "/blobs/dir/file", "v", OCTET
    get "/blobs/dir"
    assert_equal 404, last_response.status
  end

  def test_delete_blob_is_204_then_404
    put "/blobs/k", "v", OCTET
    delete "/blobs/k"
    assert_equal 204, last_response.status
    assert_equal "", last_response.body
    delete "/blobs/k"
    assert_equal 404, last_response.status
    get "/blobs/k"
    assert_equal 404, last_response.status
    get "/blobs"
    assert_equal [], body_json
  end

  def test_blob_route_rejects_unknown_methods
    post "/blobs/k"
    assert_equal 405, last_response.status
    assert_equal "GET, HEAD, PUT, DELETE", last_response.headers["allow"]
  end
end
