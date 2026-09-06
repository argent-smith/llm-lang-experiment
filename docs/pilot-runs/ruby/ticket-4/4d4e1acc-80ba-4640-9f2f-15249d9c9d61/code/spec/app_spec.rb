require "rack/test"
require "json"
require "tmpdir"
require "digest"
require_relative "../server/app"

RSpec.describe Syncbox::App do
  include Rack::Test::Methods

  def app
    Syncbox::App
  end

  around do |example|
    Dir.mktmpdir("syncbox-spec") do |dir|
      Syncbox::App.set(:data_dir, dir)
      example.run
    end
  end

  describe "GET /healthz" do
    it "responds with 200" do
      get "/healthz"

      expect(last_response.status).to eq(200)
    end
  end

  describe "GET /blobs" do
    it "responds with 200 and an empty JSON array when no blobs exist" do
      get "/blobs"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq([])
    end

    it "lists previously stored blobs with metadata, including modified_at as ISO 8601 UTC" do
      put "/blobs/dir/file.txt", "hello"

      get "/blobs"

      expect(last_response.status).to eq(200)
      entries = JSON.parse(last_response.body)
      expect(entries).to contain_exactly(
        a_hash_including(
          "key" => "dir/file.txt",
          "size" => 5,
          "sha256" => Digest::SHA256.hexdigest("hello")
        )
      )
      expect(entries.first["modified_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "lists every stored blob, across nested directories, with distinct keys" do
      put "/blobs/top.txt", "a"
      put "/blobs/dir/nested.txt", "bb"
      put "/blobs/dir/sub/deep.txt", "ccc"

      get "/blobs"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body).map { |e| e["key"] }).to contain_exactly(
        "top.txt", "dir/nested.txt", "dir/sub/deep.txt"
      )
    end
  end

  describe "PUT /blobs/:key" do
    it "responds with 201 and the stored blob's metadata" do
      put "/blobs/0", "hello"

      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)).to eq(
        "key" => "0",
        "sha256" => Digest::SHA256.hexdigest("hello"),
        "size" => 5
      )
    end

    it "never responds with 404, for a plain single-character key" do
      put "/blobs/0"

      expect(last_response.status).not_to eq(404)
    end

    it "rejects a key with a leading '..' segment with 400, not 404" do
      put "/blobs/../etc/passwd", "x"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with an embedded '..' segment with 400" do
      put "/blobs/a/../../etc/passwd", "x"

      expect(last_response.status).to eq(400)
    end

    it "rejects an empty key with 400" do
      put "/blobs/", "x"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with an embedded NUL byte with 400" do
      put "/blobs/foo%00bar", "x"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key that is not valid UTF-8 with 400" do
      put "/blobs/%ff%fe", "x"

      expect(last_response.status).to eq(400)
    end
  end

  describe "GET /blobs/:key" do
    it "responds with 200 and the stored bytes" do
      put "/blobs/0", "hello"

      get "/blobs/0"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("hello")
    end

    it "responds with 200 and the stored bytes for a key with nested directories" do
      put "/blobs/dir/file.txt", "nested content"

      get "/blobs/dir/file.txt"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("nested content")
    end

    it "responds with 404 when the blob does not exist" do
      get "/blobs/does/not/exist"

      expect(last_response.status).to eq(404)
    end
  end

  describe "DELETE /blobs/:key" do
    it "responds with 204 and no body when the blob existed" do
      put "/blobs/0", "hello"

      delete "/blobs/0"

      expect(last_response.status).to eq(204)
      expect(last_response.body).to eq("")
    end

    it "responds with 204 for a key with nested directories" do
      put "/blobs/dir/file.txt", "nested content"

      delete "/blobs/dir/file.txt"

      expect(last_response.status).to eq(204)
    end

    it "responds with 404 when the blob does not exist" do
      delete "/blobs/does/not/exist"

      expect(last_response.status).to eq(404)
    end

    it "removes the blob so a subsequent GET returns 404" do
      put "/blobs/0", "hello"

      delete "/blobs/0"
      get "/blobs/0"

      expect(last_response.status).to eq(404)
    end

    it "removes the blob so it no longer appears in GET /blobs" do
      put "/blobs/keep.txt", "keep"
      put "/blobs/gone.txt", "gone"

      delete "/blobs/gone.txt"
      get "/blobs"

      keys = JSON.parse(last_response.body).map { |e| e["key"] }
      expect(keys).to eq(["keep.txt"])
    end

    it "responds with 404 when deleting the same key twice" do
      put "/blobs/0", "hello"

      delete "/blobs/0"
      delete "/blobs/0"

      expect(last_response.status).to eq(404)
    end
  end
end
