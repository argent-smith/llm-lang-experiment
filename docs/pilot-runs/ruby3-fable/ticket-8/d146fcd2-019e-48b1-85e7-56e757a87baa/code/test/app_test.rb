# frozen_string_literal: true

require "test_helper"
require "stringio"

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
    app # хранилище уже стартовало: файл в tmp-каталоге ниже — «текущая» запись, не остаток
    FileUtils.mkdir_p(File.join(@data_dir, Syncbox::Store::TMP_DIR))
    File.write(File.join(@data_dir, Syncbox::Store::TMP_DIR, "leftover.tmp"), "x")
    FileUtils.mkdir_p(File.join(@data_dir, "empty-dir"))
    File.binwrite(File.join(@data_dir, "bad\xff".b), "x")

    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal [], json_body
  end

  def test_list_blobs_matches_openapi_blob_meta_schema
    put "/blobs/docs/readme.txt", "hello", OCTET
    put "/blobs/.hidden/empty", "", OCTET

    get "/blobs"
    list = json_body
    assert_equal 2, list.length
    list.each do |meta|
      assert_equal %w[key modified_at sha256 size], meta.keys.sort
      assert_kind_of String, meta["key"]
      assert_kind_of Integer, meta["size"]
      assert_operator meta["size"], :>=, 0
      assert_match(/\A[0-9a-f]{64}\z/, meta["sha256"])
      at = Time.iso8601(meta["modified_at"])
      assert at.utc?, "modified_at must be UTC: #{meta['modified_at']}"
      assert_in_delta Time.now.to_f, at.to_f, 60
    end
  end

  def test_list_blobs_reflects_overwrite_and_delete
    put "/blobs/k", "one", OCTET
    put "/blobs/k", "second version", OCTET
    get "/blobs"
    assert_equal [["k", 14, Digest::SHA256.hexdigest("second version")]],
                 json_body.map { |m| m.values_at("key", "size", "sha256") }

    delete "/blobs/k"
    get "/blobs"
    assert_equal [], json_body
  end

  def test_list_blobs_includes_files_placed_in_data_dir_directly
    FileUtils.mkdir_p(File.join(@data_dir, "ext", "sub"))
    File.binwrite(File.join(@data_dir, "ext", "sub", "file.bin"), "raw")

    get "/blobs"
    assert_equal 200, last_response.status
    meta = json_body.first
    assert_equal "ext/sub/file.bin", meta["key"]
    assert_equal 3, meta["size"]
    assert_equal Digest::SHA256.hexdigest("raw"), meta["sha256"]
    assert_equal File.mtime(File.join(@data_dir, "ext", "sub", "file.bin")).utc.iso8601, meta["modified_at"]
  end

  def test_list_blobs_ignores_query_string_and_rejects_trailing_slash_as_key
    put "/blobs/k", "x", OCTET
    get "/blobs?foo=bar"
    assert_equal 200, last_response.status
    assert_equal ["k"], json_body.map { |m| m["key"] }

    # /blobs/ — это GET блоба с пустым key, а не список.
    get "/blobs/"
    assert_includes [400, 404], last_response.status
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

  # Недопустимые key (тикет 5: защита от directory traversal). Каждый из них
  # обязан давать 400 на всех трёх эндпоинтах с key — и ничего не менять на
  # диске.
  INVALID_KEYS = {
    "empty" => "/blobs/",
    "trailing slash" => "/blobs/foo/",
    "double slash" => "/blobs/a//b",
    "absolute path" => "/blobs//etc/passwd",
    "encoded absolute path" => "/blobs/%2fetc%2fpasswd",
    "parent only" => "/blobs/..",
    "parent segment" => "/blobs/../etc/passwd",
    "deep parent chain" => "/blobs/../../../../../../etc/passwd",
    "parent segment in the middle" => "/blobs/a/../b",
    "parent segment at the end" => "/blobs/a/..",
    "encoded parent segment" => "/blobs/%2e%2e/etc/passwd",
    "half-encoded parent segment" => "/blobs/a/%2e./b",
    "encoded slash after parent" => "/blobs/..%2fetc%2fpasswd",
    "fully encoded traversal" => "/blobs/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
    "overlong UTF-8 dots" => "/blobs/%c0%ae%c0%ae/etc/passwd",
    "dot segment" => "/blobs/./a",
    "NUL byte" => "/blobs/a%00b",
    "NUL before parent segment" => "/blobs/a%00/../../etc/passwd",
    "invalid UTF-8" => "/blobs/%ff",
    "truncated UTF-8 sequence" => "/blobs/%c3",
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

    define_method("test_get_rejects_#{name.tr(' -', '__')}_with_400") do
      get path
      assert_equal 400, last_response.status, "GET #{path}"
      assert_equal "invalid_key", json_body["error"]
    end

    define_method("test_delete_rejects_#{name.tr(' -', '__')}_with_400") do
      delete path
      assert_equal 400, last_response.status, "DELETE #{path}"
      assert_equal "invalid_key", json_body["error"]
    end
  end

  def test_invalid_key_response_explains_the_reason
    put "/blobs/../etc/passwd", "x", OCTET
    assert_equal 400, last_response.status
    assert_match %r{\Aapplication/json}, last_response.content_type
    assert_equal "invalid_key", json_body["error"]
    assert_match(/'\.\.'/, json_body["message"])
  end

  def test_key_is_decoded_exactly_once_so_double_encoded_parent_is_a_literal_name
    put "/blobs/%252e%252e/x", "x", OCTET
    assert_equal 201, last_response.status
    assert_equal "%2e%2e/x", json_body["key"]
    assert_equal "x", File.binread(File.join(@data_dir, "%2e%2e", "x"))
    get "/blobs/%252e%252e/x"
    assert_equal 200, last_response.status
  end

  def test_keys_that_only_look_like_traversal_are_stored_inside_the_data_dir
    ["...", "..a", "a..", "a\\..\\b", "~", "a/..%2f.."].each do |key|
      put "/blobs/#{Rack::Utils.escape_path(key)}", key, OCTET
      assert_equal 201, last_response.status, "PUT #{key.inspect}"
      assert_equal key, json_body["key"]
      assert_equal key, File.binread(File.join(@data_dir, key))
    end
  end

  def test_traversal_through_symlink_inside_data_dir_is_rejected_on_every_endpoint
    Dir.mktmpdir("syncbox-outside") do |outside|
      canary = File.join(outside, "canary")
      File.binwrite(canary, "canary")
      File.symlink(outside, File.join(@data_dir, "escape"))

      put "/blobs/escape/pwned", "pwned", OCTET
      assert_equal 400, last_response.status
      assert_equal "invalid_key", json_body["error"]
      refute File.exist?(File.join(outside, "pwned"))

      get "/blobs/escape/canary"
      assert_equal 400, last_response.status

      delete "/blobs/escape/canary"
      assert_equal 400, last_response.status
      assert_equal "canary", File.binread(canary)

      put "/blobs/escape", "pwned", OCTET
      assert_equal 400, last_response.status, "a key resolving to a directory outside the root is invalid"
      assert_equal "canary", File.binread(canary)

      get "/blobs"
      assert_equal 200, last_response.status
      assert_equal [], json_body, "files reachable only through an escaping symlink are not blobs"
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
    assert_equal({ "error" => "not_found" }, json_body)
  end

  def test_delete_missing_blob_in_missing_directory_returns_404
    delete "/blobs/no/such/dir/file.txt"
    assert_equal 404, last_response.status
  end

  def test_delete_204_has_no_body_and_no_content_type
    put "/blobs/k", "x", OCTET
    delete "/blobs/k"
    assert_equal 204, last_response.status
    assert_empty last_response.body
    assert_nil last_response.headers["content-type"]
  end

  def test_deleted_blob_disappears_from_list_but_others_remain
    put "/blobs/a.txt", "a", OCTET
    put "/blobs/docs/b.txt", "b", OCTET
    put "/blobs/docs/c.txt", "c", OCTET

    delete "/blobs/docs/b.txt"
    assert_equal 204, last_response.status

    get "/blobs"
    assert_equal %w[a.txt docs/c.txt], json_body.map { |m| m["key"] }
    get "/blobs/docs/b.txt"
    assert_equal 404, last_response.status
    get "/blobs/docs/c.txt"
    assert_equal "c", last_response.body
  end

  def test_delete_decodes_percent_encoded_key
    put "/blobs/dir%20name/%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82.txt", "x", OCTET
    delete "/blobs/dir%20name/%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82.txt"
    assert_equal 204, last_response.status
    refute File.exist?(File.join(@data_dir, "dir name"))
    get "/blobs"
    assert_equal [], json_body
  end

  def test_delete_directory_key_returns_404_and_keeps_children
    put "/blobs/dir/child", "x", OCTET
    delete "/blobs/dir"
    assert_equal 404, last_response.status
    get "/blobs/dir/child"
    assert_equal 200, last_response.status
  end

  def test_delete_key_under_existing_file_returns_404
    put "/blobs/file", "x", OCTET
    delete "/blobs/file/child"
    assert_equal 404, last_response.status
    assert_equal "x", File.binread(File.join(@data_dir, "file"))
  end

  def test_delete_removes_file_placed_in_data_dir_directly
    FileUtils.mkdir_p(File.join(@data_dir, "ext"))
    File.binwrite(File.join(@data_dir, "ext", "on-disk"), "raw")
    delete "/blobs/ext/on-disk"
    assert_equal 204, last_response.status
    refute File.exist?(File.join(@data_dir, "ext"))
  end

  def test_key_can_be_put_as_file_after_deleting_blobs_beneath_it
    put "/blobs/d/e/f", "x", OCTET
    delete "/blobs/d/e/f"
    put "/blobs/d", "now a file", OCTET
    assert_equal 201, last_response.status
    get "/blobs/d"
    assert_equal "now a file", last_response.body
  end

  def test_delete_then_put_same_key_again_works
    put "/blobs/k", "one", OCTET
    delete "/blobs/k"
    put "/blobs/k", "two", OCTET
    assert_equal 201, last_response.status
    get "/blobs/k"
    assert_equal "two", last_response.body
    get "/blobs"
    assert_equal [["k", Digest::SHA256.hexdigest("two")]], json_body.map { |m| m.values_at("key", "sha256") }
  end

  def test_delete_ignores_query_string
    put "/blobs/k", "x", OCTET
    delete "/blobs/k?force=true"
    assert_equal 204, last_response.status
  end

  def test_wrong_method_on_blob_key_returns_405
    post "/blobs/x"
    assert_equal 405, last_response.status
    assert_equal "GET, PUT, DELETE", last_response.headers["allow"]
  end

  # --- тикет 6: атомарность записи ---------------------------------------------

  # Тело запроса, обрывающееся после первых байт — обрыв соединения клиента
  # посреди загрузки (если бы сервер отдавал тело приложению потоково).
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

  def raw_put(key, input)
    env = Rack::MockRequest.env_for("/blobs/#{key}", method: "PUT", input: input,
                                                     "CONTENT_TYPE" => "application/octet-stream")
    status, headers, body = app.call(env)
    [status, headers, body.join]
  end

  def test_put_with_interrupted_body_returns_500_keeps_old_blob_and_leaves_no_temp_file
    put "/blobs/k", "old", OCTET
    tmp_dir = File.join(@data_dir, Syncbox::Store::TMP_DIR)

    status = body = nil
    _out, err = capture_io { status, _headers, body = raw_put("k", BrokenInput.new("partial")) }
    assert_equal 500, status
    assert_equal({ "error" => "internal_error" }, JSON.parse(body))
    assert_match(/IOError: client disconnected/, err)

    assert_empty Dir.children(tmp_dir), "temp file must not outlive the failed request"
    get "/blobs/k"
    assert_equal 200, last_response.status
    assert_equal "old", last_response.body
    get "/blobs"
    assert_equal [["k", 3, Digest::SHA256.hexdigest("old")]], json_body.map { |m| m.values_at("key", "size", "sha256") }
  end

  def test_in_flight_temp_file_is_not_served_or_listed_even_though_it_exists_on_disk
    app # хранилище уже стартовало: файл ниже — «текущая» запись, не остаток
    tmp_dir = File.join(@data_dir, Syncbox::Store::TMP_DIR)
    FileUtils.mkdir_p(tmp_dir)
    File.binwrite(File.join(tmp_dir, "0123.tmp"), "in flight")

    get "/blobs/#{Syncbox::Store::TMP_DIR}/0123.tmp"
    assert_equal 400, last_response.status
    get "/blobs/#{Syncbox::Store::TMP_DIR}"
    assert_equal 400, last_response.status
    delete "/blobs/#{Syncbox::Store::TMP_DIR}/0123.tmp"
    assert_equal 400, last_response.status
    assert File.exist?(File.join(tmp_dir, "0123.tmp")), "the API must not touch an in-flight temp file"
    get "/blobs"
    assert_equal [], json_body
  end

  def test_stale_temp_files_are_swept_when_the_app_starts
    tmp_dir = File.join(@data_dir, Syncbox::Store::TMP_DIR)
    FileUtils.mkdir_p(tmp_dir)
    File.binwrite(File.join(tmp_dir, "deadbeef.tmp"), "left behind by a killed server")
    app
    assert_empty Dir.children(tmp_dir)
  end

  def test_concurrent_puts_to_the_same_key_yield_one_complete_version
    app # создать приложение до запуска потоков: rack-test не потокобезопасен, потоки зовут #call сами
    size = Syncbox::Store::CHUNK_SIZE * 3 + 1
    versions = ("A".."D").map { |c| c.b * size }
    problems = Queue.new

    threads = versions.map do |version|
      Thread.new do
        3.times do
          status, _headers, body = raw_put("hot", version)
          ok = status == 201 && JSON.parse(body)["sha256"] == Digest::SHA256.hexdigest(version)
          problems << "PUT -> #{status} #{body}" unless ok
        end
      rescue StandardError => e
        problems << e
      end
    end
    threads.each(&:join)
    assert_empty Array.new(problems.size) { problems.pop }

    get "/blobs/hot"
    assert_equal 200, last_response.status
    assert_equal size.to_s, last_response.headers["content-length"]
    assert_includes versions, last_response.body.b
    assert_empty Dir.children(File.join(@data_dir, Syncbox::Store::TMP_DIR))
  end
end
