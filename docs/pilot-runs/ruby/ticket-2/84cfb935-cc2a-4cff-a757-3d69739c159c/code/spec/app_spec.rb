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

    it "lists previously stored blobs with metadata" do
      put "/blobs/dir/file.txt", "hello"

      get "/blobs"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to contain_exactly(
        a_hash_including(
          "key" => "dir/file.txt",
          "size" => 5,
          "sha256" => Digest::SHA256.hexdigest("hello")
        )
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
end
