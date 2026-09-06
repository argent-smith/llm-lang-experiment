require "json"
require_relative "../client/server_client"

RSpec.describe Syncbox::ServerClient do
  let(:client) { described_class.new("http://example.test:8080") }

  describe "#list_blobs" do
    it "returns the parsed JSON array from GET /blobs" do
      entries = [{"key" => "a.txt", "size" => 1, "sha256" => "x", "modified_at" => "2020-01-01T00:00:00Z"}]
      stub_request(:get, "http://example.test:8080/blobs").to_return(status: 200, body: entries.to_json)

      expect(client.list_blobs).to eq(entries)
    end

    it "raises ConnectionError when the server is unreachable" do
      stub_request(:get, "http://example.test:8080/blobs").to_raise(Errno::ECONNREFUSED)

      expect { client.list_blobs }.to raise_error(Syncbox::ServerClient::ConnectionError)
    end

    it "raises RequestError on an unexpected status" do
      stub_request(:get, "http://example.test:8080/blobs").to_return(status: 500)

      expect { client.list_blobs }.to raise_error(Syncbox::ServerClient::RequestError)
    end
  end

  describe "#get_blob" do
    it "returns the raw bytes from GET /blobs/:key" do
      stub_request(:get, "http://example.test:8080/blobs/dir/file.txt").to_return(status: 200, body: "hello")

      expect(client.get_blob("dir/file.txt")).to eq("hello")
    end

    it "percent-encodes special characters in a key segment while preserving '/'" do
      stub = stub_request(:get, "http://example.test:8080/blobs/dir/a%20b.txt").to_return(status: 200, body: "x")

      client.get_blob("dir/a b.txt")

      expect(stub).to have_been_requested
    end

    it "raises RequestError on an unexpected status" do
      stub_request(:get, "http://example.test:8080/blobs/missing.txt").to_return(status: 404)

      expect { client.get_blob("missing.txt") }.to raise_error(Syncbox::ServerClient::RequestError)
    end

    it "raises ConnectionError when the server is unreachable" do
      stub_request(:get, "http://example.test:8080/blobs/x.txt").to_raise(Errno::ECONNREFUSED)

      expect { client.get_blob("x.txt") }.to raise_error(Syncbox::ServerClient::ConnectionError)
    end
  end

  describe "#put_blob" do
    it "PUTs the raw bytes to /blobs/:key with an octet-stream content type" do
      stub = stub_request(:put, "http://example.test:8080/blobs/dir/file.txt")
        .with(body: "hello", headers: {"Content-Type" => "application/octet-stream"})
        .to_return(status: 201, body: {"key" => "dir/file.txt", "sha256" => "x", "size" => 5}.to_json)

      client.put_blob("dir/file.txt", "hello")

      expect(stub).to have_been_requested
    end

    it "percent-encodes special characters in a key segment while preserving '/'" do
      stub = stub_request(:put, "http://example.test:8080/blobs/dir/a%20b.txt").to_return(status: 201, body: "{}")

      client.put_blob("dir/a b.txt", "x")

      expect(stub).to have_been_requested
    end

    it "raises RequestError when the server responds with an unexpected status" do
      stub_request(:put, "http://example.test:8080/blobs/bad.txt").to_return(status: 400)

      expect { client.put_blob("bad.txt", "x") }.to raise_error(Syncbox::ServerClient::RequestError)
    end

    it "raises ConnectionError when the server is unreachable" do
      stub_request(:put, "http://example.test:8080/blobs/x.txt").to_raise(Errno::ECONNREFUSED)

      expect { client.put_blob("x.txt", "y") }.to raise_error(Syncbox::ServerClient::ConnectionError)
    end
  end
end
