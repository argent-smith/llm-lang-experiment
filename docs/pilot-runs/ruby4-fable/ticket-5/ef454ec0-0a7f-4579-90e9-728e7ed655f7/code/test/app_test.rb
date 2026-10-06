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

  # --- DELETE /blobs/{key} (ticket 4) --------------------------------------

  def test_delete_blob_is_204_without_body
    put "/blobs/k", "v", OCTET
    delete "/blobs/k"
    assert_equal 204, last_response.status
    assert_equal "", last_response.body
    assert_nil last_response.headers["content-type"]
    assert_nil last_response.headers["content-length"]
    refute File.exist?(File.join(@data_dir, "blobs", "k"))
  end

  def test_deleted_blob_is_gone_from_get_and_list
    put "/blobs/docs/readme.txt", "hello", OCTET
    put "/blobs/keep", "me", OCTET
    delete "/blobs/docs/readme.txt"
    assert_equal 204, last_response.status

    get "/blobs/docs/readme.txt"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not found" }, body_json)
    get "/blobs"
    assert_equal ["keep"], body_json.map { |m| m["key"] }
    get "/blobs/keep"
    assert_equal 200, last_response.status
    assert_equal "me", last_response.body
  end

  def test_delete_missing_blob_is_404
    delete "/blobs/missing"
    assert_equal 404, last_response.status
    assert_equal "application/json", last_response.headers["content-type"]
    assert_equal({ "error" => "not found" }, body_json)
    delete "/blobs/no/such/dir/file"
    assert_equal 404, last_response.status
  end

  def test_delete_is_not_idempotent_in_status_code
    put "/blobs/k", "v", OCTET
    delete "/blobs/k"
    assert_equal 204, last_response.status
    delete "/blobs/k"
    assert_equal 404, last_response.status
  end

  def test_delete_of_a_directory_key_is_404_and_keeps_its_contents
    put "/blobs/dir/a", "a", OCTET
    put "/blobs/dir/b", "b", OCTET
    delete "/blobs/dir"
    assert_equal 404, last_response.status
    delete "/blobs/dir/"
    assert_includes [400, 404], last_response.status
    get "/blobs"
    assert_equal %w[dir/a dir/b], body_json.map { |m| m["key"] }
  end

  def test_delete_decodes_percent_encoded_key
    put "/blobs/sp%20ace/%C3%BC%2Bplus.txt", "v", OCTET
    assert_equal "sp ace/ü+plus.txt", body_json["key"]
    delete "/blobs/sp%20ace/%C3%BC%2Bplus.txt"
    assert_equal 204, last_response.status
    get "/blobs"
    assert_equal [], body_json
  end

  def test_delete_removes_directories_it_leaves_empty_but_not_the_root
    put "/blobs/a/b/c/leaf", "v", OCTET
    put "/blobs/a/sibling", "s", OCTET
    root = File.join(@data_dir, "blobs")

    delete "/blobs/a/b/c/leaf"
    assert_equal 204, last_response.status
    refute File.exist?(File.join(root, "a", "b")), "emptied a/b/c and a/b should be pruned"
    assert File.directory?(File.join(root, "a")), "a/ still holds a/sibling"

    delete "/blobs/a/sibling"
    assert_equal 204, last_response.status
    refute File.exist?(File.join(root, "a"))
    assert File.directory?(root), "storage root must survive deleting the last blob"
    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal [], body_json
  end

  def test_key_freed_by_delete_can_be_reused_as_a_file_or_directory
    put "/blobs/docs/readme.txt", "v", OCTET
    delete "/blobs/docs/readme.txt"
    assert_equal 204, last_response.status

    put "/blobs/docs", "now a file", OCTET
    assert_equal 201, last_response.status
    get "/blobs/docs"
    assert_equal "now a file", last_response.body

    delete "/blobs/docs"
    assert_equal 204, last_response.status
    put "/blobs/docs/readme.txt", "and a directory again", OCTET
    assert_equal 201, last_response.status
    get "/blobs"
    assert_equal ["docs/readme.txt"], body_json.map { |m| m["key"] }
  end

  def test_delete_ignores_request_body_and_query_string
    put "/blobs/k", "v", OCTET
    delete "/blobs/k?force=true", "ignored body", OCTET
    assert_equal 204, last_response.status
    get "/blobs/k"
    assert_equal 404, last_response.status
  end

  def test_delete_then_put_then_get_round_trip
    put "/blobs/k", "one", OCTET
    delete "/blobs/k"
    put "/blobs/k", "two", OCTET
    assert_equal 201, last_response.status
    get "/blobs/k"
    assert_equal 200, last_response.status
    assert_equal "two", last_response.body
    get "/blobs"
    assert_equal [{ "key" => "k", "size" => 3 }], body_json.map { |m| m.slice("key", "size") }
  end

  def test_blob_route_rejects_unknown_methods
    post "/blobs/k"
    assert_equal 405, last_response.status
    assert_equal "GET, HEAD, PUT, DELETE", last_response.headers["allow"]
  end

  # --- directory traversal protection (ticket 5) ---------------------------

  # Every way of spelling ".." or an absolute path in a request path that a
  # client could try: raw, percent-encoded (upper and lower case), mixed,
  # with the slash encoded, deep, and combined with "." segments.
  TRAVERSAL_PATHS = [
    "/blobs/..", "/blobs/../secret", "/blobs/../../secret", "/blobs/a/../../secret", "/blobs/a/b/../../../secret",
    "/blobs/%2e%2e/secret", "/blobs/%2E%2E/secret", "/blobs/.%2e/secret", "/blobs/%2e./secret",
    "/blobs/..%2Fsecret", "/blobs/..%2fsecret", "/blobs/%2e%2e%2Fsecret", "/blobs/%2E%2E%2F%2E%2E%2Fsecret",
    "/blobs/a%2F..%2F..%2Fsecret", "/blobs/a/..%2F../secret", "/blobs/./../secret", "/blobs/a/./../../secret",
    "/blobs/#{'../' * 10}etc/passwd", "/blobs/#{'%2e%2e%2f' * 10}etc%2fpasswd",
    "/blobs//secret", "/blobs///secret", "/blobs/%2Fsecret", "/blobs/%2F%2Fsecret", "/blobs/%2fetc%2fpasswd",
    "/blobs//etc/passwd", "/blobs/%2F"
  ].freeze

  UNREPRESENTABLE_PATHS = [
    "/blobs/%00", "/blobs/a%00b", "/blobs/a/%00", "/blobs/%ED%A0%80", "/blobs/x/%ED%A0%80",
    "/blobs/%FF", "/blobs/ok/%FF", "/blobs/%C3", "/blobs/%C0%AE%C0%AE/secret", "/blobs/%C0%AE%C0%AE%2Fsecret",
    "/blobs/%F4%90%80%80", "/blobs/#{'x' * 256}", "/blobs/#{'x' * 256}/y", "/blobs/y/#{'x' * 256}",
    "/blobs/", "/blobs//", "/blobs/a/", "/blobs/a//b", "/blobs/.", "/blobs/%2e", "/blobs/./a", "/blobs/a/./b"
  ].freeze

  def plant_secret
    File.write(File.join(@data_dir, "secret"), "s3cret")
  end

  def assert_invalid_key_on_every_method(path)
    put path, "planted", OCTET
    assert_equal 400, last_response.status, "PUT #{path}"
    assert_equal "application/json", last_response.headers["content-type"], "PUT #{path}"
    assert_equal "invalid key", body_json["error"], "PUT #{path}"

    get path
    assert_equal 400, last_response.status, "GET #{path}"
    assert_equal "invalid key", body_json["error"], "GET #{path}"
    refute_includes last_response.body, "s3cret", "GET #{path} leaked a file outside the root"

    head path
    assert_equal 400, last_response.status, "HEAD #{path}"

    delete path
    assert_equal 400, last_response.status, "DELETE #{path}"
    assert_equal "invalid key", body_json["error"], "DELETE #{path}"
  end

  def assert_data_dir_untouched(expected_children)
    assert_equal expected_children.sort, Dir.children(@data_dir).sort, "a rejected key must not create anything"
    assert_equal "s3cret", File.read(File.join(@data_dir, "secret")), "file outside the root must be untouched"
  end

  def test_traversal_and_absolute_keys_are_400_on_every_method
    plant_secret
    TRAVERSAL_PATHS.each { |path| assert_invalid_key_on_every_method(path) }
    assert_data_dir_untouched(["secret"])
    get "/blobs"
    assert_equal [], body_json
  end

  def test_keys_that_cannot_be_file_names_are_400_on_every_method
    plant_secret
    UNREPRESENTABLE_PATHS.each { |path| assert_invalid_key_on_every_method(path) }
    assert_data_dir_untouched(["secret"])
  end

  def test_traversal_is_rejected_even_when_the_target_exists_inside_the_data_dir
    plant_secret
    put "/blobs/docs/readme.txt", "legit", OCTET
    # Reaching an existing blob via a detour through ".." is still traversal.
    ["/blobs/docs/../docs/readme.txt", "/blobs/../blobs/docs/readme.txt", "/blobs/other/../docs/readme.txt",
     "/blobs/docs/%2e%2e/docs/readme.txt"].each do |path|
      get path
      assert_equal 400, last_response.status, path
      delete path
      assert_equal 400, last_response.status, path
    end
    get "/blobs/docs/readme.txt"
    assert_equal "legit", last_response.body
    assert_data_dir_untouched(%w[blobs secret tmp])
  end

  def test_double_encoded_dot_dot_is_a_literal_name_not_traversal
    plant_secret
    put "/blobs/%252e%252e/secret", "literal", OCTET
    assert_equal 201, last_response.status
    assert_equal "%2e%2e/secret", body_json["key"]
    assert File.file?(File.join(@data_dir, "blobs", "%2e%2e", "secret"))
    get "/blobs/%252e%252e/secret"
    assert_equal 200, last_response.status
    assert_equal "literal", last_response.body
    get "/blobs/..%252fsecret"
    assert_equal 404, last_response.status
    assert_data_dir_untouched(%w[blobs secret tmp])
  end

  def test_dot_dot_inside_a_segment_is_a_valid_key
    ["...", "a..b", "..a", "a..", "dir../x", "x/..y"].each do |key|
      put "/blobs/#{key}", key, OCTET
      assert_equal 201, last_response.status, key
      get "/blobs/#{key}"
      assert_equal 200, last_response.status, key
      assert_equal key, last_response.body
    end
  end

  def test_symlink_inside_the_store_cannot_lead_outside_the_root
    root = File.join(@data_dir, "blobs")
    outside = File.join(@data_dir, "outside")
    FileUtils.mkdir_p(root)
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "secret"), "s3cret")
    File.symlink(outside, File.join(root, "link"))
    File.symlink(File.join(outside, "secret"), File.join(root, "flink"))
    File.symlink("/", File.join(root, "rootlink"))
    put "/blobs/real", "r", OCTET

    ["/blobs/link/secret", "/blobs/link", "/blobs/link/new/deeper", "/blobs/flink", "/blobs/rootlink/etc/passwd",
     "/blobs/rootlink"].each do |path|
      get path
      assert_equal 400, last_response.status, "GET #{path}"
      refute_includes last_response.body, "s3cret"
      put path, "planted", OCTET
      assert_equal 400, last_response.status, "PUT #{path}"
      delete path
      assert_equal 400, last_response.status, "DELETE #{path}"
    end
    assert_equal ["secret"], Dir.children(outside)
    assert_equal "s3cret", File.read(File.join(outside, "secret"))
    assert File.symlink?(File.join(root, "flink"))
    get "/blobs"
    assert_equal ["real"], body_json.map { |m| m["key"] }
  end

  def test_query_string_and_fragment_do_not_change_the_key
    put "/blobs/k?x=../secret", "v", OCTET
    assert_equal 201, last_response.status
    assert_equal "k", body_json["key"]
    get "/blobs/k?path=../../etc/passwd"
    assert_equal 200, last_response.status
    assert_equal "v", last_response.body
  end
end
