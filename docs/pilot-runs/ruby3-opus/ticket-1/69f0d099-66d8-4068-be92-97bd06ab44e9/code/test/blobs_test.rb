# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "rack/lint"
require "rack/test"

# PUT /blobs/{key} and GET /blobs: every response must be one the OpenAPI
# schema declares for the operation (201/400 and 200), whatever the key.
class BlobsTest < Minitest::Test
  include Rack::Test::Methods

  EMPTY_SHA256 = Digest::SHA256.hexdigest("")

  def setup
    @root = Dir.mktmpdir
    @data_dir = File.join(@root, "data")
    Dir.mkdir(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def app
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080)
    Rack::Lint.new(Syncbox::Server::Runner.build_app(config))
  end

  def test_list_is_empty_on_fresh_data_dir
    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type
    assert_equal [], JSON.parse(last_response.body)
  end

  def test_head_list_returns_200
    head "/blobs"
    assert_equal 200, last_response.status
  end

  def test_put_without_body_stores_empty_blob
    put "/blobs/0", nil, "CONTENT_TYPE" => "application/octet-stream"
    assert_equal 201, last_response.status
    assert_equal "application/json", last_response.content_type
    assert_equal({ "key" => "0", "sha256" => EMPTY_SHA256, "size" => 0 }, JSON.parse(last_response.body))
  end

  def test_put_stores_bytes_and_list_reports_metadata
    body = "hello\x00\xFFworld".b
    put "/blobs/docs/readme.txt", body
    assert_equal 201, last_response.status
    sha = Digest::SHA256.hexdigest(body)
    assert_equal({ "key" => "docs/readme.txt", "sha256" => sha, "size" => body.bytesize }, JSON.parse(last_response.body))

    get "/blobs"
    assert_equal 200, last_response.status
    entries = JSON.parse(last_response.body)
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal({ "key" => "docs/readme.txt", "size" => body.bytesize, "sha256" => sha }, entry.except("modified_at"))
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/, entry["modified_at"])
    assert_in_delta Time.now.to_f, Time.iso8601(entry["modified_at"]).to_f, 60
  end

  def test_put_overwrites_existing_blob
    put "/blobs/a", "first"
    put "/blobs/a", "second"
    assert_equal 201, last_response.status

    get "/blobs"
    entries = JSON.parse(last_response.body)
    assert_equal [["a", 6, Digest::SHA256.hexdigest("second")]], entries.map { |e| e.values_at("key", "size", "sha256") }
  end

  def test_list_is_sorted_by_key
    %w[b a/z a/b c].each { |key| put "/blobs/#{key}", key }
    get "/blobs"
    assert_equal %w[a/b a/z b c], JSON.parse(last_response.body).map { |e| e["key"] }
  end

  def test_put_decodes_percent_encoded_key
    put "/blobs/a%20b/%C3%A9t%C3%A9+x%3F"
    assert_equal 201, last_response.status
    assert_equal "a b/été+x?", JSON.parse(last_response.body)["key"]
  end

  def test_put_accepts_raw_utf8_key
    put_raw "/blobs/é/ü.txt".b
    assert_equal 201, last_response.status
    assert_equal "é/ü.txt", JSON.parse(last_response.body)["key"]
  end

  def test_put_rejects_invalid_keys_with_400
    invalid = [
      "",                    # empty key
      "..", "a/../b", "a/..", "%2e%2e/x", "..%2Fx", "a%2F..%2F..%2Fx", # traversal
      "/etc/passwd", "%2Fetc%2Fpasswd",                                # absolute path
      ".", "./a", "a/./b", "a//b", "a/", "a%2F%2Fb",                   # non-canonical paths
      "%00", "a%00b",                                                  # NUL
      "%FF", "%C3", "%ED%A0%80", "%ED%B0%80", "%C0%AF",                # not representable as UTF-8 (incl. surrogates)
      "%", "%z", "%zz", "a%2", "%%41",                                 # malformed percent-encoding
      "a" * 256,                                                       # file name too long
      "#{'ab/' * 2000}x"                                               # path too long
    ]
    invalid.each do |key|
      put_raw "/blobs/#{key}".b
      assert_equal 400, last_response.status, "key #{key[0, 40].inspect}"
    end
    put_raw "/blobs/\xFF\xFE".b
    assert_equal 400, last_response.status

    assert_nothing_stored_outside_store
    get "/blobs"
    assert_equal [], JSON.parse(last_response.body)
  end

  def test_put_rejecting_too_long_key_creates_no_directories
    put "/blobs/#{'d/' * 100}#{'n' * 256}", "x"
    assert_equal 400, last_response.status
    put "/blobs/#{'d/' * 2100}f", "x"
    assert_equal 400, last_response.status
    assert_equal [], Dir.exist?(File.join(@data_dir, "blobs")) ? Dir.children(File.join(@data_dir, "blobs")) : []
  end

  def test_put_rejects_key_below_existing_blob
    put "/blobs/a", "file"
    put "/blobs/a/b", "nested"
    assert_equal 400, last_response.status
  end

  def test_put_rejects_key_naming_existing_directory
    put "/blobs/a/b", "nested"
    put "/blobs/a", "file"
    assert_equal 400, last_response.status

    get "/blobs"
    assert_equal ["a/b"], JSON.parse(last_response.body).map { |e| e["key"] }
  end

  def test_put_garbage_keys_never_leaves_contract
    rng = Random.new(20_261_003)
    alphabet = ["a", "Z", "0", ".", "..", "/", "%", "%2F", "%2e", "%00", "%FF", "%C3%A9", "%ED%A0%80",
                " ", "+", "?", "%23", "\\", "~", "-", "_", "\xC3\xA9".b, "\xFF".b, "\x01".b]
    500.times do
      key = Array.new(rng.rand(0..12)) { alphabet.sample(random: rng) }.join.b
      put_raw "/blobs/#{key}".b, "x"
      assert_includes [201, 400], last_response.status, "key #{key.inspect}"
    end

    get "/blobs"
    assert_equal 200, last_response.status
    JSON.parse(last_response.body).each do |entry|
      assert_equal %w[key modified_at sha256 size], entry.keys.sort
    end
    assert_nothing_stored_outside_store
  end

  def test_list_skips_foreign_entries_in_store
    put "/blobs/ok", "x"
    blobs = File.join(@data_dir, "blobs")
    File.write(File.join(blobs, "bad-\xFF-name".b), "x")
    File.symlink("/etc/passwd", File.join(blobs, "link"))

    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal ["ok"], JSON.parse(last_response.body).map { |e| e["key"] }
  end

  def test_list_works_when_data_dir_has_non_ascii_name
    @data_dir = File.join(@root, "dáta")
    put_raw "/blobs/é".b, "x"
    assert_equal 201, last_response.status

    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal ["é"], JSON.parse(last_response.body).map { |e| e["key"] }
  end

  private

  # Sends PUT with an arbitrary raw path, bypassing URI parsing in rack-test.
  def put_raw(path, body = "")
    put "/blobs/placeholder", body, "PATH_INFO" => path
  end

  def assert_nothing_stored_outside_store
    assert_equal [], Dir.children(@data_dir) - %w[blobs tmp]
    tmp = File.join(@data_dir, "tmp")
    assert_equal [], Dir.children(tmp), "staging files left behind" if File.directory?(tmp)
  end
end
