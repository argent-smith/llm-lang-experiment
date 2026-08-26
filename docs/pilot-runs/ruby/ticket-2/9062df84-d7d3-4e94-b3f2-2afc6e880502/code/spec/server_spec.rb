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
end
