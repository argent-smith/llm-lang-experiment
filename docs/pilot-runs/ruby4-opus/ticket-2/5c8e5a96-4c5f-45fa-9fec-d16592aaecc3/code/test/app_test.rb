# frozen_string_literal: true

require "test_helper"
require "json"
require "rack/mock"

class AppTest < Minitest::Test
  SHA256_EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  SHA256_HELLO = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

  def setup
    @data_dir = Dir.mktmpdir
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: "8080")
    @rack_app = Syncbox::Server::App.new(config)
    @app = Rack::MockRequest.new(@rack_app)
  end

  def teardown
    FileUtils.rm_rf(@data_dir)
  end

  def test_healthz
    response = @app.get("/healthz")

    assert_equal 200, response.status
  end

  def test_healthz_head
    assert_equal 200, @app.head("/healthz").status
  end

  def test_healthz_rejects_other_methods
    %i[post put delete patch].each do |method|
      response = @app.request(method.to_s.upcase, "/healthz")

      assert_equal 405, response.status, method
      assert_equal "GET, HEAD", response.headers["allow"]
    end
  end

  def test_unknown_paths_are_not_found
    ["/", "/healthz/", "/healthzz", "/nope"].each do |path|
      assert_equal 404, @app.get(path).status, path
    end
  end
  def test_list_blobs_is_empty_initially
    response = @app.get("/blobs")

    assert_equal 200, response.status
    assert_equal "application/json", response.headers["content-type"]
    assert_equal [], JSON.parse(response.body)
  end

  def test_list_blobs_head
    assert_equal 200, @app.head("/blobs").status
  end

  def test_list_blobs_ignores_query_string
    assert_equal 200, @app.get("/blobs?limit=-1&key=..").status
  end

  def test_list_blobs_rejects_other_methods
    %i[post put delete patch].each do |method|
      response = @app.request(method.to_s.upcase, "/blobs")

      assert_equal 405, response.status, method
      assert_equal "GET, HEAD", response.headers["allow"]
    end
  end

  def test_put_blob_without_body
    response = put("/blobs/0", nil)

    assert_equal 201, response.status
    assert_equal "application/json", response.headers["content-type"]
    assert_equal({ "key" => "0", "sha256" => SHA256_EMPTY, "size" => 0 }, JSON.parse(response.body))
  end

  def test_put_blob_stores_content
    response = put("/blobs/docs/readme.txt", "hello")

    assert_equal 201, response.status
    assert_equal({ "key" => "docs/readme.txt", "sha256" => SHA256_HELLO, "size" => 5 }, JSON.parse(response.body))
    assert_equal "hello", File.binread(File.join(@data_dir, "blobs", "docs", "readme.txt"))
  end

  def test_put_blob_decodes_key
    assert_equal "a/b c/\u2713", JSON.parse(put("/blobs/a%2Fb%20c/%E2%9C%93", "x").body)["key"]
    assert_equal ["a/b c/\u2713"], list.map { |blob| blob["key"] }
  end

  def test_put_blob_overwrites
    put("/blobs/f", "old")
    response = put("/blobs/f", "hello")

    assert_equal 201, response.status
    assert_equal [{ "key" => "f", "size" => 5, "sha256" => SHA256_HELLO }],
                 list.map { |blob| blob.slice("key", "size", "sha256") }
  end

  def test_get_blob_returns_stored_bytes
    content = (0..255).map(&:chr).join.b * 1000 # binary, several read chunks
    put("/blobs/docs/data.bin", content)
    response = @app.get("/blobs/docs/data.bin")

    assert_equal 200, response.status
    assert_equal "application/octet-stream", response.headers["content-type"]
    assert_equal content.bytesize.to_s, response.headers["content-length"]
    assert_equal content, response.body.b
  end

  def test_get_blob_empty
    put("/blobs/empty", nil)
    response = @app.get("/blobs/empty")

    assert_equal 200, response.status
    assert_equal "", response.body
  end

  def test_get_blob_returns_latest_version
    put("/blobs/f", "old")
    put("/blobs/f", "hello")

    assert_equal "hello", @app.get("/blobs/f").body
  end

  def test_get_blob_decodes_key
    put("/blobs/a/b c/✓".b, "x")

    assert_equal "x", @app.get("/blobs/a%2Fb%20c%2F%E2%9C%93").body
  end

  def test_get_blob_head
    put("/blobs/f", "hello")
    response = @app.head("/blobs/f")

    assert_equal 200, response.status
    assert_equal "5", response.headers["content-length"]
  end

  def test_get_missing_blob_is_not_found
    put("/blobs/dir/file", "x")

    ["/blobs/missing", "/blobs/dir/missing", "/blobs/dir", "/blobs/dir/file/sub"].each do |path|
      assert_equal 404, @app.get(path).status, path
    end
  end

  def test_blob_rejects_other_methods
    %i[post patch].each do |method|
      response = @app.request(method.to_s.upcase, "/blobs/f")

      assert_equal 405, response.status, method
      assert_equal "GET, HEAD, PUT", response.headers["allow"]
    end
  end

  def test_list_blobs_returns_metadata
    put("/blobs/b/nested", "hello")
    put("/blobs/a", "")
    blobs = list

    assert_equal %w[a b/nested], blobs.map { |blob| blob["key"] }
    assert_equal [0, 5], blobs.map { |blob| blob["size"] }
    assert_equal [SHA256_EMPTY, SHA256_HELLO], blobs.map { |blob| blob["sha256"] }
    blobs.each { |blob| assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/, blob["modified_at"]) }
  end

  def test_put_blob_rejects_invalid_keys
    put("/blobs/ok", "x")
    [
      "/blobs/", "/blobs//", "/blobs/%2F", "/blobs//etc/passwd", "/blobs/%2Fetc%2Fpasswd",
      "/blobs/..", "/blobs/../x", "/blobs/a/../../x", "/blobs/..%2F..%2Fx", "/blobs/%2E%2E/x",
      "/blobs/.", "/blobs/a/./b", "/blobs/a//b", "/blobs/a/",
      "/blobs/%00", "/blobs/a%00b", # NUL byte
      "/blobs/%ED%A0%80", "/blobs/%FF", "/blobs/%C0%AF", "/blobs/\xFF\xFE".b, # not UTF-8 (incl. surrogate)
      "/blobs/%", "/blobs/%zz", "/blobs/%2", # malformed escapes
      "/blobs/#{'a' * 256}", "/blobs/#{'b/' * 2100}c", "/blobs/#{"#{'a' * 200}/" * 30}z" # too long
    ].each do |path|
      assert_equal 400, put(path, "x").status, path.inspect
    end
    assert_equal %w[ok], list.map { |blob| blob["key"] }
    assert_equal %w[ok], Dir.children(File.join(@data_dir, "blobs")), "rejected keys must not leave directories"
    assert_equal [], Dir.children(File.join(@data_dir, "tmp")), "rejected keys must not leave temporary files"
  end

  def test_put_blob_rejects_keys_clashing_with_stored_blobs
    put("/blobs/file", "x")
    put("/blobs/dir/inner", "x")

    assert_equal 400, put("/blobs/file/inner", "y").status
    assert_equal 400, put("/blobs/dir", "y").status
    assert_equal %w[dir/inner file], list.map { |blob| blob["key"] }
  end

  def test_keys_named_like_internal_directories_are_ordinary_blobs
    assert_equal 201, put("/blobs/tmp", "x").status
    assert_equal 201, put("/blobs/blobs/tmp", "x").status
    assert_equal %w[blobs/tmp tmp], list.map { |blob| blob["key"] }
  end

  def test_list_blobs_handles_deeply_nested_keys
    key = "#{'d/' * 2000}z"

    assert_equal 201, put("/blobs/#{key}", "x").status
    assert_equal [key], list.map { |blob| blob["key"] }
  end

  def test_list_blobs_skips_entries_that_are_not_valid_keys
    put("/blobs/ok", "x")
    blobs_dir = File.join(@data_dir, "blobs")
    File.binwrite(File.join(blobs_dir, "\xFF\xFE".b), "x")
    File.symlink("/etc/passwd", File.join(blobs_dir, "link"))

    assert_equal %w[ok], list.map { |blob| blob["key"] }
  end

  private

  # Builds the request by hand so that PATH_INFO reaches the app exactly as
  # given, like the raw request path Puma passes through.
  def put(path, body)
    env = Rack::MockRequest.env_for("/", method: "PUT", input: body, "CONTENT_TYPE" => "application/octet-stream")
    env["PATH_INFO"] = path
    env.delete("rack.input") if body.nil?
    Rack::MockResponse.new(*@rack_app.call(env))
  end

  def list
    JSON.parse(@app.get("/blobs").body)
  end
end
