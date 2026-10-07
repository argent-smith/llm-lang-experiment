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
      assert_equal "GET, HEAD, PUT, DELETE", response.headers["allow"]
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

  def test_delete_blob
    put("/blobs/0", "x")
    put("/blobs/keep", "y")
    response = delete("/blobs/0")

    assert_equal 204, response.status
    assert_equal "", response.body
    assert_equal 404, @app.get("/blobs/0").status
    assert_equal %w[keep], list.map { |blob| blob["key"] }
  end

  def test_delete_blob_decodes_key
    put("/blobs/a/b c/✓".b, "x")

    assert_equal 204, delete("/blobs/a%2Fb%20c%2F%E2%9C%93").status
    assert_equal [], list
  end

  def test_delete_missing_blob_is_not_found
    put("/blobs/dir/file", "x")

    ["/blobs/0", "/blobs/missing", "/blobs/dir/missing", "/blobs/dir", "/blobs/dir/file/sub",
     "/blobs/#{'a' * 255}", "/blobs/#{'b/' * 2100}c", "/blobs/#{"#{'a' * 200}/" * 30}z"].each do |path|
      assert_equal 404, delete(path).status, path[0, 40]
    end
    assert_equal %w[dir/file], list.map { |blob| blob["key"] }
  end

  def test_delete_blob_twice
    put("/blobs/f", "x")

    assert_equal 204, delete("/blobs/f").status
    assert_equal 404, delete("/blobs/f").status
  end

  def test_delete_blob_does_not_follow_symlinks
    put("/blobs/ok", "x")
    File.symlink("/etc/passwd", File.join(@data_dir, "blobs", "link"))

    assert_equal 404, delete("/blobs/link").status
    assert File.symlink?(File.join(@data_dir, "blobs", "link"))
  end

  def test_delete_blob_removes_emptied_directories
    put("/blobs/a/b/c", "x")
    put("/blobs/a/keep", "x")

    assert_equal 204, delete("/blobs/a/b/c").status
    assert_equal %w[keep], Dir.children(File.join(@data_dir, "blobs", "a"))
    assert_equal 201, put("/blobs/a/b", "y").status, "the deleted blob's directory must not clash with a new key"
    assert_equal 204, delete("/blobs/a/keep").status
    assert_equal 204, delete("/blobs/a/b").status
    assert_equal [], Dir.children(File.join(@data_dir, "blobs"))
    assert_equal 201, put("/blobs/a", "z").status
  end

  def test_concurrent_put_and_delete_in_one_directory
    statuses = Array.new(4) do |i|
      Thread.new do
        Array.new(200) do
          [put("/blobs/shared/sub/#{i}", "x").status, delete("/blobs/shared/sub/#{i}").status]
        end
      end
    end.flat_map(&:value)

    assert_equal [[201, 204]], statuses.uniq
    assert_equal [], list
  end

  def test_delete_blob_rejects_invalid_keys
    put("/blobs/ok", "x")
    invalid_key_paths.each do |path|
      assert_equal 400, delete(path).status, path.inspect[0, 40]
    end
    assert_equal %w[ok], list.map { |blob| blob["key"] }
  end

  def test_get_and_delete_answer_within_contract_for_any_key
    put("/blobs/f", "x")
    put("/blobs/dir/file", "x")
    paths = invalid_key_paths + ["/blobs/0", "/blobs/f/sub", "/blobs/dir", "/blobs/%25", "/blobs/%2525",
                                 "/blobs/?", "/blobs/ ", "/blobs/\u{1F600}".b, "/blobs/%F0%9F%98%80",
                                 "/blobs/...", "/blobs/.hidden", "/blobs/a\..\b"]
    paths.each do |path|
      assert_includes [200, 404, 400], request("GET", path).status, "GET #{path.inspect[0, 40]}"
      assert_includes [204, 404, 400], request("DELETE", path).status, "DELETE #{path.inspect[0, 40]}"
    end
  end

  def test_traversal_keys_are_rejected_by_every_blob_endpoint
    outside = File.join(@data_dir, "outside")
    File.binwrite(outside, "secret")
    File.binwrite("#{@data_dir}/blobs-outside", "secret") # shares a prefix with the blobs directory
    put("/blobs/ok", "x")
    traversal_key_paths.each do |path|
      %w[PUT GET DELETE].each do |method|
        assert_equal 400, request(method, path, method == "PUT" ? "evil" : nil).status, "#{method} #{path.inspect}"
      end
    end
    assert_equal "secret", File.binread(outside)
    assert_equal "secret", File.binread("#{@data_dir}/blobs-outside")
    assert_equal %w[blobs blobs-outside outside tmp], Dir.children(@data_dir).sort
    assert_equal %w[ok], list.map { |blob| blob["key"] }
  end

  def test_keys_merely_resembling_traversal_are_ordinary_blobs
    # "%2E%2E" arrives as "%252E%252E": decoded once, it is a literal name.
    keys = ["...", "a..b", "..a", "a..", ".hidden", "a/.../b", "a\\b", "a\\.\\b", "~", "~root/x", "C:", "%2E%2E"]
    keys.each do |key|
      path = "/blobs/#{key.gsub('%', '%25')}"

      assert_equal 201, put(path, key).status, key
      assert_equal key, request("GET", path).body, key
      assert_equal key, File.binread(File.join(@data_dir, "blobs", key)), key
    end
    assert_equal keys.sort, list.map { |blob| blob["key"] }
    keys.each { |key| assert_equal 204, delete("/blobs/#{key.gsub('%', '%25')}").status, key }
  end

  def test_blob_endpoints_do_not_follow_symlinked_directories_out_of_the_store
    outside = Dir.mktmpdir
    File.binwrite(File.join(outside, "secret"), "secret")
    blobs_dir = File.join(@data_dir, "blobs")
    FileUtils.mkdir_p(File.join(blobs_dir, "real"))
    File.symlink(outside, File.join(blobs_dir, "out"))
    File.symlink(File.join(outside, "missing"), File.join(blobs_dir, "dangling"))
    File.symlink("../..", File.join(blobs_dir, "real", "up"))

    ["out/secret", "out/new", "dangling/new", "real/up/x", "out/a/b/c"].each do |key|
      assert_equal 400, put("/blobs/#{key}", "evil").status, "PUT #{key}"
    end
    ["out/secret", "real/up/outside"].each do |key|
      assert_equal 400, @app.get("/blobs/#{key}").status, "GET #{key}"
      assert_equal 400, delete("/blobs/#{key}").status, "DELETE #{key}"
    end
    assert_equal %w[secret], Dir.children(outside)
    assert_equal "secret", File.binread(File.join(outside, "secret"))
    assert_equal [], list
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_blob_endpoints_work_through_a_symlinked_data_directory
    real = File.join(@data_dir, "real")
    link = File.join(@data_dir, "link")
    Dir.mkdir(real)
    File.symlink(real, link)
    app = Syncbox::Server::App.new(Syncbox::Server::Config.new(data_dir: link, port: "8080"))

    assert_equal 201, request("PUT", "/blobs/a/b", "x", app: app).status
    assert_equal "x", request("GET", "/blobs/a/b", app: app).body
    assert_equal 204, request("DELETE", "/blobs/a/b", app: app).status
    assert_equal 400, request("PUT", "/blobs/..%2Fx", "x", app: app).status
    assert_equal %w[blobs tmp], Dir.children(real).sort
  end

  def test_blob_endpoints_never_fail_on_arbitrary_keys
    random = Random.new(5)
    alphabet = ["a", "/", ".", "..", "\\", "%", "%2F", "%2E", "%00", "%FF", "%ED%A0%80", "~", " ", "\xC3".b, "\xA9".b]
    paths = Array.new(400) { "/blobs/#{Array.new(random.rand(1..8)) { alphabet.sample(random: random) }.join}" }
    paths += Array.new(50) { "/blobs/#{random.bytes(random.rand(1..16))}" }
    paths += ["/blobs/\xFF".dup.force_encoding(Encoding::UTF_8), "/blobs/a/\xC3".dup.force_encoding(Encoding::UTF_8)]
    paths.each do |path|
      assert_includes [201, 400], request("PUT", path, "x").status, "PUT #{path.inspect}"
      assert_includes [200, 400, 404], request("GET", path).status, "GET #{path.inspect}"
      assert_includes [204, 400, 404], request("DELETE", path).status, "DELETE #{path.inspect}"
    end
    assert_equal %w[blobs tmp], Dir.children(@data_dir).sort
  end

  def test_upload_in_progress_is_not_reachable_through_the_api
    put("/blobs/f", "old")
    tmp_dir = File.join(@data_dir, "tmp")
    seen = []
    look_around = lambda do
      name = Dir.children(tmp_dir).first
      seen << [request("GET", "/blobs/f").body, list.map { |blob| blob["key"] },
               request("GET", "/blobs/#{name}").status, request("GET", "/blobs/..%2Ftmp%2F#{name}").status]
    end
    chunks = ["new"] * 3
    input = Object.new
    input.define_singleton_method(:read) do |_length, buffer|
      look_around.call
      (chunk = chunks.shift) && buffer.replace(chunk)
    end
    env = Rack::MockRequest.env_for("/blobs/f", method: "PUT", input: "")
    env["rack.input"] = input

    assert_equal 201, @rack_app.call(env).first
    assert_equal [["old", %w[f], 404, 400]], seen.uniq
    assert_equal "newnewnew", request("GET", "/blobs/f").body
    assert_equal [], Dir.children(tmp_dir)
  end

  def test_upload_interrupted_mid_body_leaves_no_trace
    put("/blobs/f", "old")
    input = Object.new
    input.define_singleton_method(:read) { |*| raise EOFError, "client went away" }
    env = Rack::MockRequest.env_for("/blobs/f", method: "PUT", input: "")
    env["rack.input"] = input

    assert_raises(EOFError) { @rack_app.call(env) }
    assert_equal "old", request("GET", "/blobs/f").body
    assert_equal [], Dir.children(File.join(@data_dir, "tmp"))
  end

  private

  # Request paths with a key that tries to leave the store, in various spellings.
  def traversal_key_paths
    [
      "/blobs/..", "/blobs/../outside", "/blobs/../blobs-outside", "/blobs/a/../../outside", "/blobs/a/b/../../../outside",
      "/blobs/..%2Foutside", "/blobs/%2E%2E%2Foutside", "/blobs/%2e%2e/outside", "/blobs/a%2F..%2F..%2Foutside",
      "/blobs/ok/..", "/blobs/ok/../../outside",
      "/blobs//etc/passwd", "/blobs/%2Fetc%2Fpasswd", "/blobs/%2F%2E%2E%2Foutside",
      "/blobs/..\\outside", "/blobs/a\\..\\..\\outside", "/blobs/%5C..%5Coutside", "/blobs/\\etc\\passwd",
      "/blobs/..%00/outside", "/blobs/%C0%AE%C0%AE/outside" # NUL; overlong UTF-8 for "."
    ]
  end

  # Builds the request by hand so that PATH_INFO reaches the app exactly as
  # given, like the raw request path Puma passes through.
  def put(path, body)
    request("PUT", path, body)
  end

  def delete(path)
    request("DELETE", path)
  end

  def request(method, path, body = nil, app: @rack_app)
    env = Rack::MockRequest.env_for("/", method: method, input: body, "CONTENT_TYPE" => "application/octet-stream")
    env["PATH_INFO"] = path
    env.delete("rack.input") if body.nil?
    Rack::MockResponse.new(*app.call(env))
  end

  # Request paths whose key every blob operation must reject with 400.
  def invalid_key_paths
    [
      "/blobs/", "/blobs//", "/blobs/%2F", "/blobs//etc/passwd", "/blobs/%2Fetc%2Fpasswd",
      "/blobs/..", "/blobs/../x", "/blobs/a/../../x", "/blobs/..%2F..%2Fx", "/blobs/%2E%2E/x",
      "/blobs/.", "/blobs/a/./b", "/blobs/a//b", "/blobs/a/",
      "/blobs/%00", "/blobs/a%00b", # NUL byte
      "/blobs/%ED%A0%80", "/blobs/%FF", "/blobs/%C0%AF", "/blobs/\xFF\xFE".b, # not UTF-8 (incl. surrogate)
      "/blobs/%", "/blobs/%zz", "/blobs/%2", # malformed escapes
      "/blobs/#{'a' * 256}" # segment too long
    ]
  end

  def list
    JSON.parse(@app.get("/blobs").body)
  end
end
