# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "stringio"
require "rack/lint"
require "rack/test"

# GET /blobs: metadata of every blob stored on the server.
class ListBlobsTest < Minitest::Test
  include Rack::Test::Methods

  ISO8601_UTC = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/

  def setup
    @data_dir = Dir.mktmpdir
    @blobs_dir = File.join(@data_dir, "blobs")
  end

  def teardown
    FileUtils.remove_entry(@data_dir)
  end

  def app
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080)
    Rack::Lint.new(Syncbox::Server::Runner.build_app(config))
  end

  def test_empty_store_lists_empty_array
    get "/blobs"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type
    assert_equal "[]", last_response.body

    # Blobs directory exists but holds only empty subdirectories.
    FileUtils.mkdir_p(File.join(@blobs_dir, "a", "b"))
    get "/blobs"
    assert_equal [], listing
  end

  def test_lists_every_blob_with_metadata
    blobs = { "top.txt" => "top", "docs/readme.txt" => "read me", "docs/img/logo.png" => "\x89PNG\x00\xFF".b,
              "empty" => "", ".hidden" => "h", "é/ü.txt" => "unicode" }
    blobs.each { |key, body| put "/blobs/#{key.split('/').map { |s| URI.encode_uri_component(s) }.join('/')}", body }

    entries = listing
    assert_equal blobs.keys.sort, entries.map { |e| e["key"] }
    entries.each do |entry|
      body = blobs.fetch(entry["key"])
      assert_equal %w[key modified_at sha256 size], entry.keys.sort
      assert_equal body.bytesize, entry["size"]
      assert_equal Digest::SHA256.hexdigest(body), entry["sha256"]
      assert_match ISO8601_UTC, entry["modified_at"]
    end
  end

  def test_lists_blobs_placed_directly_on_disk
    write_on_disk("docs/readme.txt", "hello")
    write_on_disk("a/b/c/d.bin", "\x00\x01".b)

    assert_equal [["a/b/c/d.bin", 2, Digest::SHA256.hexdigest("\x00\x01")],
                  ["docs/readme.txt", 5, Digest::SHA256.hexdigest("hello")]],
                 listing.map { |e| e.values_at("key", "size", "sha256") }
  end

  def test_modified_at_is_file_mtime_in_utc
    path = write_on_disk("docs/old.txt", "x")
    File.utime(Time.utc(2001, 2, 3, 4, 5, 6.25r), Time.utc(2001, 2, 3, 4, 5, 6.25r), path)

    modified_at = listing.first["modified_at"]
    assert_match ISO8601_UTC, modified_at
    assert_equal Time.utc(2001, 2, 3, 4, 5, 6.25r), Time.iso8601(modified_at)
  end

  def test_modified_at_advances_on_overwrite
    put "/blobs/a", "first"
    File.utime(Time.utc(2000), Time.utc(2000), File.join(@blobs_dir, "a"))
    put "/blobs/a", "second"

    entry = listing.first
    assert_equal Digest::SHA256.hexdigest("second"), entry["sha256"]
    assert_operator Time.iso8601(entry["modified_at"]), :>, Time.utc(2020)
  end

  def test_lists_keys_that_need_percent_encoding
    put "/blobs/a%20b/%C3%A9t%C3%A9+x%3F%25", "x"
    assert_equal ["a b/été+x?%"], listing.map { |e| e["key"] }
  end

  def test_skips_unreadable_blob
    skip "root can read anything" if Process.uid.zero?

    put "/blobs/ok", "x"
    File.chmod(0o000, write_on_disk("secret", "x"))
    assert_equal ["ok"], listing.map { |e| e["key"] }
  end

  def test_skips_symlinks_and_special_files
    put "/blobs/ok", "x"
    write_on_disk("dir/real", "x")
    File.symlink(File.join(@blobs_dir, "dir"), File.join(@blobs_dir, "dirlink"))
    File.symlink("/etc/hostname", File.join(@blobs_dir, "filelink"))
    File.mkfifo(File.join(@blobs_dir, "fifo"))

    assert_equal %w[dir/real ok], listing.map { |e| e["key"] }
  end

  def test_staging_area_is_not_listed
    write_on_disk("ok", "x")
    FileUtils.mkdir_p(File.join(@data_dir, "tmp"))
    File.write(File.join(@data_dir, "tmp", "upload.part"), "partial")

    assert_equal ["ok"], listing.map { |e| e["key"] }
  end

  def test_entries_stay_consistent_while_blobs_are_overwritten
    versions = ["", "a", "b" * 70_000, "c" * 200_000].to_h { |v| [v.bytesize, Digest::SHA256.hexdigest(v)] }
    put "/blobs/hot", ""
    store = Syncbox::Server::Store.new(@data_dir)
    writer = Thread.new do
      300.times { |i| store.put("hot", StringIO.new("abc"[i % 3] * versions.keys[(i % 3) + 1])) }
    end

    while writer.alive?
      store.list.each do |entry|
        assert_equal versions.fetch(entry[:size]), entry[:sha256], "size and sha256 from different versions"
      end
    end
    writer.join
  end

  def test_head_returns_200_without_body
    put "/blobs/a", "x"
    head "/blobs"
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end

  def test_rejects_other_methods_with_405
    %i[post put delete patch].each do |verb|
      send(verb, "/blobs")
      assert_equal 405, last_response.status, verb.to_s
      assert_equal "GET, HEAD", last_response.headers["allow"]
    end
    assert_equal [], listing
  end

  private

  def listing
    get "/blobs"
    assert_equal 200, last_response.status
    JSON.parse(last_response.body)
  end

  def write_on_disk(key, body)
    path = File.join(@blobs_dir, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    path
  end
end
