require "spec_helper"
require "syncbox/server"
require "digest"
require "json"
require "tmpdir"

RSpec.describe Syncbox::Server do
  include Rack::Test::Methods

  def app
    Syncbox::Server
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @data_dir = dir
      Syncbox::Server.set(:data_dir, dir)
      example.run
    end
  end

  describe "GET /healthz" do
    it "returns 200" do
      get "/healthz", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(200)
    end
  end

  describe "PUT /blobs/:key" do
    it "stores the body and returns 201 with key, sha256 and size" do
      body = "hello world"

      put "/blobs/greeting.txt", body, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(201)
      expect(last_response.content_type).to eq("application/json")

      json = JSON.parse(last_response.body)
      expect(json).to eq(
        "key" => "greeting.txt",
        "sha256" => Digest::SHA256.hexdigest(body),
        "size" => body.bytesize
      )
      expect(File.binread(File.join(@data_dir, "greeting.txt"))).to eq(body)
    end

    it "creates nested directories as needed" do
      body = "nested content"

      put "/blobs/docs/readme.txt", body, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(201)
      expect(File.binread(File.join(@data_dir, "docs", "readme.txt"))).to eq(body)
    end

    it "overwrites an existing blob stored under the same key" do
      put "/blobs/file.txt", "first version", { "HTTP_HOST" => "localhost" }
      put "/blobs/file.txt", "second version", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(201)
      json = JSON.parse(last_response.body)
      expect(json["sha256"]).to eq(Digest::SHA256.hexdigest("second version"))
      expect(File.binread(File.join(@data_dir, "file.txt"))).to eq("second version")
    end

    it "round-trips arbitrary binary content" do
      body = (0..255).to_a.pack("C*")

      put "/blobs/binary.bin", body, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(201)
      json = JSON.parse(last_response.body)
      expect(json["sha256"]).to eq(Digest::SHA256.hexdigest(body))
      expect(json["size"]).to eq(256)
      expect(File.binread(File.join(@data_dir, "binary.bin"))).to eq(body)
    end

    it "stores the full body even when sent as application/x-www-form-urlencoded" do
      # curl defaults --data/--data-binary to this content type, and Sinatra's
      # own params parsing would otherwise drain rack.input before the route
      # runs, storing an empty blob. Regression test for that trap.
      body = "a=1&b=2"

      put "/blobs/form-like.txt", body, { "HTTP_HOST" => "localhost", "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

      expect(last_response.status).to eq(201)
      json = JSON.parse(last_response.body)
      expect(json["size"]).to eq(body.bytesize)
      expect(json["sha256"]).to eq(Digest::SHA256.hexdigest(body))
      expect(File.binread(File.join(@data_dir, "form-like.txt"))).to eq(body)
    end
  end

  describe "GET /blobs/:key" do
    it "returns 404 when the blob does not exist" do
      get "/blobs/missing.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "returns the stored bytes with 200 and octet-stream content type" do
      body = "round trip content"
      put "/blobs/file.txt", body, { "HTTP_HOST" => "localhost" }

      get "/blobs/file.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to eq("application/octet-stream")
      expect(last_response.body).to eq(body)
    end

    it "retrieves blobs stored under nested directories" do
      body = "nested get"
      put "/blobs/a/b/c.txt", body, { "HTTP_HOST" => "localhost" }

      get "/blobs/a/b/c.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq(body)
    end
  end

  describe "DELETE /blobs/:key" do
    it "returns 404 when the blob does not exist" do
      delete "/blobs/missing.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "deletes an existing blob and returns 204 with an empty body" do
      put "/blobs/file.txt", "content", { "HTTP_HOST" => "localhost" }

      delete "/blobs/file.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(204)
      expect(last_response.body).to eq("")
      expect(File.exist?(File.join(@data_dir, "file.txt"))).to be(false)
    end

    it "deletes a blob stored under nested directories" do
      put "/blobs/a/b/c.txt", "nested", { "HTTP_HOST" => "localhost" }

      delete "/blobs/a/b/c.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(204)
      expect(File.exist?(File.join(@data_dir, "a", "b", "c.txt"))).to be(false)
    end

    it "makes the blob subsequently return 404 on GET" do
      put "/blobs/file.txt", "content", { "HTTP_HOST" => "localhost" }
      delete "/blobs/file.txt", {}, { "HTTP_HOST" => "localhost" }

      get "/blobs/file.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "removes the blob from the GET /blobs listing" do
      put "/blobs/keep.txt", "keep", { "HTTP_HOST" => "localhost" }
      put "/blobs/gone.txt", "gone", { "HTTP_HOST" => "localhost" }

      delete "/blobs/gone.txt", {}, { "HTTP_HOST" => "localhost" }
      get "/blobs", {}, { "HTTP_HOST" => "localhost" }

      json = JSON.parse(last_response.body)
      expect(json.map { |b| b["key"] }).to eq(["keep.txt"])
    end

    it "returns 404 on a second delete of the same key" do
      put "/blobs/file.txt", "content", { "HTTP_HOST" => "localhost" }
      delete "/blobs/file.txt", {}, { "HTTP_HOST" => "localhost" }

      delete "/blobs/file.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end
  end

  describe "GET /blobs" do
    it "returns 200 and an empty array when the store is empty" do
      get "/blobs", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to eq("application/json")
      expect(JSON.parse(last_response.body)).to eq([])
    end

    it "lists a stored blob with key, size, sha256 and modified_at" do
      body = "hello world"
      put "/blobs/greeting.txt", body, { "HTTP_HOST" => "localhost" }

      get "/blobs", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json.length).to eq(1)

      entry = json.first
      expect(entry["key"]).to eq("greeting.txt")
      expect(entry["size"]).to eq(body.bytesize)
      expect(entry["sha256"]).to eq(Digest::SHA256.hexdigest(body))
      expect(entry["modified_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "reflects the current content and size after an overwrite" do
      put "/blobs/file.txt", "first version", { "HTTP_HOST" => "localhost" }
      put "/blobs/file.txt", "second version", { "HTTP_HOST" => "localhost" }

      get "/blobs", {}, { "HTTP_HOST" => "localhost" }

      json = JSON.parse(last_response.body)
      entry = json.find { |b| b["key"] == "file.txt" }
      expect(entry["sha256"]).to eq(Digest::SHA256.hexdigest("second version"))
      expect(entry["size"]).to eq("second version".bytesize)
    end

    it "includes blobs nested under directories using a POSIX-style relative key" do
      put "/blobs/docs/readme.txt", "nested content", { "HTTP_HOST" => "localhost" }

      get "/blobs", {}, { "HTTP_HOST" => "localhost" }

      json = JSON.parse(last_response.body)
      expect(json.map { |b| b["key"] }).to eq(["docs/readme.txt"])
    end

    it "lists every stored blob regardless of nesting depth" do
      put "/blobs/top.txt", "top", { "HTTP_HOST" => "localhost" }
      put "/blobs/docs/readme.txt", "readme", { "HTTP_HOST" => "localhost" }
      put "/blobs/a/b/c.txt", "deep", { "HTTP_HOST" => "localhost" }

      get "/blobs", {}, { "HTTP_HOST" => "localhost" }

      json = JSON.parse(last_response.body)
      expect(json.map { |b| b["key"] }).to contain_exactly("top.txt", "docs/readme.txt", "a/b/c.txt")
    end
  end
end
