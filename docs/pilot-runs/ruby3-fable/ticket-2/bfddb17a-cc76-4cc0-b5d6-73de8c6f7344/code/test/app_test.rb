# frozen_string_literal: true

require "test_helper"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  OCTET = { "CONTENT_TYPE" => "application/octet-stream" }.freeze

  def setup
    @data_dir = Dir.mktmpdir("syncbox-app")
  end

  def teardown
    FileUtils.remove_entry(@data_dir) if @data_dir && File.exist?(@data_dir)
  end

  def app
    @app ||= Syncbox::App.new(Syncbox::Config.new(data_dir: @data_dir))
  end

  def json_body
    JSON.parse(last_response.body)
  end

  def test_healthz_returns_200
    get "/healthz"
    assert_equal 200, last_response.status
    assert_match %r{\Aapplication/json}, last_response.content_type
    assert_equal({ "status" => "ok" }, json_body)
  end

  def test_head_healthz_returns_200_without_body
    head "/healthz"
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end

  def test_unknown_path_returns_404_json
    get "/nope"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not_found" }, json_body)
  end

  def test_wrong_method_on_known_path_returns_405
    post "/healthz"
    assert_equal 405, last_response.status
    assert_equal "GET", last_response.headers["allow"]
  end

  # --- GET /blobs: схема объявляет только 200 ---

  def test_list_blobs_on_empty_store_returns_200_and_empty_array
    get "/blobs"
    assert_equal 200, last_response.status
    assert_match %r{\Aapplication/json}, last_response.content_type
    assert_equal [], json_body
  end

  def test_head_blobs_returns_200_without_body
    head "/blobs"
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end

  def test_list_blobs_returns_metadata_sorted_by_key
    put "/blobs/docs/readme.txt", "hello", OCTET
    put "/blobs/a.bin", "\x00\xff".b, OCTET

    get "/blobs"
    assert_equal 200, last_response.status
    list = json_body
    assert_equal %w[a.bin docs/readme.txt], list.map { |m| m["key"] }

    readme = list.last
    assert_equal 5, readme["size"]
    assert_equal Digest::SHA256.hexdigest("hello"), readme["sha256"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, readme["modified_at"])
    assert_equal %w[key modified_at sha256 size], readme.keys.sort
  end

  def test_list_blobs_skips_temp_dir_and_non_key_entries
    FileUtils.mkdir_p(File.join(@data_dir, Syncbox::Store::TMP_DIR))
    File.write(File.join(@data_dir, Syncbox::Store::TMP_DIR, "leftover.tmp"), "x")
    FileUtils.mkdir_p(File.join(@data_dir, "empty-dir"))
    File.binwrite(File.join(@data_dir, "bad\xff".b), "x")

    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal [], json_body
  end

  # --- PUT /blobs/{key}: схема объявляет только 201, 400 ---

  def test_put_numeric_key_with_empty_body_returns_201
    put "/blobs/0", "", OCTET
    assert_equal 201, last_response.status
    assert_equal({ "key" => "0", "sha256" => Digest::SHA256.hexdigest(""), "size" => 0 }, json_body)
    assert_equal "", File.binread(File.join(@data_dir, "0"))
  end

  def test_put_without_content_type_still_stores_raw_bytes
    put "/blobs/raw", "payload"
    assert_equal 201, last_response.status
    assert_equal "payload", File.binread(File.join(@data_dir, "raw"))
  end

  def test_put_then_get_roundtrip_binary
    payload = (0..255).map(&:chr).join.b * 3
    put "/blobs/docs/bin.dat", payload, OCTET
    assert_equal 201, last_response.status
    assert_equal({ "key" => "docs/bin.dat", "sha256" => Digest::SHA256.hexdigest(payload), "size" => payload.bytesize }, json_body)

    get "/blobs/docs/bin.dat"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert_equal payload.bytesize.to_s, last_response.headers["content-length"]
    assert_equal payload, last_response.body.b
  end

  def test_put_overwrites_existing_blob
    put "/blobs/k", "one", OCTET
    put "/blobs/k", "two", OCTET
    assert_equal 201, last_response.status
    get "/blobs/k"
    assert_equal "two", last_response.body
  end

  def test_put_decodes_percent_encoded_key
    put "/blobs/dir%20name/%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82.txt", "x", OCTET
    assert_equal 201, last_response.status
    assert_equal "dir name/привет.txt", json_body["key"]
    assert File.file?(File.join(@data_dir, "dir name", "привет.txt"))

    get "/blobs"
    assert_equal ["dir name/привет.txt"], json_body.map { |m| m["key"] }
  end

  def test_put_leaves_no_temp_files_behind
    put "/blobs/t", "x", OCTET
    tmp_dir = File.join(@data_dir, Syncbox::Store::TMP_DIR)
    assert_empty Dir.children(tmp_dir)
  end

  def test_put_creates_nested_directories_on_disk
    put "/blobs/x/y/z/file.txt", "deep", OCTET
    assert_equal 201, last_response.status
    assert_equal({ "key" => "x/y/z/file.txt", "sha256" => Digest::SHA256.hexdigest("deep"), "size" => 4 }, json_body)
    %w[x x/y x/y/z].each { |dir| assert File.directory?(File.join(@data_dir, dir)), "#{dir} should exist" }
    assert_equal "deep", File.binread(File.join(@data_dir, "x", "y", "z", "file.txt"))
  end

  def test_put_sha256_is_lowercase_hex_of_body
    put "/blobs/sum", "The quick brown fox jumps over the lazy dog", OCTET
    assert_equal "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592", json_body["sha256"]
    assert_equal 43, json_body["size"]
  end

  def test_put_two_keys_in_same_directory_keep_both
    put "/blobs/dir/one", "1", OCTET
    put "/blobs/dir/two", "2", OCTET
    get "/blobs/dir/one"
    assert_equal "1", last_response.body
    get "/blobs/dir/two"
    assert_equal "2", last_response.body
  end

  INVALID_KEYS = {
    "empty" => "/blobs/",
    "trailing slash" => "/blobs/foo/",
    "double slash" => "/blobs/a//b",
    "absolute path" => "/blobs//etc/passwd",
    "parent segment" => "/blobs/../etc/passwd",
    "parent segment in the middle" => "/blobs/a/../b",
    "encoded parent segment" => "/blobs/%2e%2e/etc/passwd",
    "dot segment" => "/blobs/./a",
    "NUL byte" => "/blobs/a%00b",
    "invalid UTF-8" => "/blobs/%ff",
    "UTF-16 surrogate" => "/blobs/%ed%a0%80",
    "overlong segment" => "/blobs/#{'x' * 256}",
    "reserved temp dir" => "/blobs/#{Syncbox::Store::TMP_DIR}/x"
  }.freeze

  INVALID_KEYS.each do |name, path|
    define_method("test_put_rejects_#{name.tr(' -', '__')}_with_400") do
      put path, "x", OCTET
      assert_equal 400, last_response.status, "PUT #{path}"
      assert_equal "invalid_key", json_body["error"]
      assert_equal [], Dir.children(@data_dir) - [Syncbox::Store::TMP_DIR], "nothing must be written for #{path}"
    end

    define_method("test_get_rejects_#{name.tr(' -', '__')}_with_400_or_404") do
      get path
      assert_includes [400, 404], last_response.status, "GET #{path}"
    end

    define_method("test_delete_rejects_#{name.tr(' -', '__')}_with_400_or_404") do
      delete path
      assert_includes [400, 404], last_response.status, "DELETE #{path}"
    end
  end

  def test_put_rejects_key_under_existing_file_with_400
    put "/blobs/file", "x", OCTET
    put "/blobs/file/child", "y", OCTET
    assert_equal 400, last_response.status
    assert_equal "x", File.binread(File.join(@data_dir, "file"))
  end

  def test_put_rejects_key_that_is_a_directory_with_400
    put "/blobs/dir/child", "x", OCTET
    put "/blobs/dir", "y", OCTET
    assert_equal 400, last_response.status
    assert_equal "x", File.binread(File.join(@data_dir, "dir", "child"))
  end

  def test_put_rejects_key_exceeding_path_max_with_400
    key = Array.new(40) { "s" * 200 }.join("/")
    put "/blobs/#{key}", "x", OCTET
    assert_equal 400, last_response.status
  end

  # --- GET /blobs/{key}: 200, 404, 400 ---

  def test_get_missing_blob_returns_404
    get "/blobs/missing"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not_found" }, json_body)
  end

  def test_get_missing_blob_in_missing_directory_returns_404
    get "/blobs/no/such/dir/file.txt"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not_found" }, json_body)
  end

  def test_get_missing_blob_next_to_existing_one_returns_404
    put "/blobs/docs/a.txt", "a", OCTET
    get "/blobs/docs/b.txt"
    assert_equal 404, last_response.status
  end

  def test_get_directory_key_returns_404
    put "/blobs/dir/child", "x", OCTET
    get "/blobs/dir"
    assert_equal 404, last_response.status
  end

  def test_head_blob_returns_200_without_body
    put "/blobs/h", "abc", OCTET
    head "/blobs/h"
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end

  # --- DELETE /blobs/{key}: 204, 404, 400 ---

  def test_delete_existing_blob_returns_204_then_404
    put "/blobs/d/e/f", "x", OCTET
    delete "/blobs/d/e/f"
    assert_equal 204, last_response.status
    assert_empty last_response.body
    refute File.exist?(File.join(@data_dir, "d")), "empty parent dirs should be pruned"

    get "/blobs/d/e/f"
    assert_equal 404, last_response.status
    delete "/blobs/d/e/f"
    assert_equal 404, last_response.status
  end

  def test_delete_keeps_siblings_and_their_dirs
    put "/blobs/d/one", "1", OCTET
    put "/blobs/d/two", "2", OCTET
    delete "/blobs/d/one"
    assert_equal 204, last_response.status
    get "/blobs/d/two"
    assert_equal 200, last_response.status
  end

  def test_delete_missing_blob_returns_404
    delete "/blobs/missing"
    assert_equal 404, last_response.status
  end

  def test_wrong_method_on_blob_key_returns_405
    post "/blobs/x"
    assert_equal 405, last_response.status
    assert_equal "GET, PUT, DELETE", last_response.headers["allow"]
  end
end
