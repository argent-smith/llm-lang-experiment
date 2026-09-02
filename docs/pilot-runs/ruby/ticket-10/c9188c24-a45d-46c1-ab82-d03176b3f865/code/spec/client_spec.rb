require "spec_helper"
require_relative "support/test_server"
require "syncbox/client"
require "digest"
require "tmpdir"

RSpec.describe Syncbox::Client do
  around do |example|
    Dir.mktmpdir do |dir|
      @data_dir = dir
      @server = TestServer.start(dir)
      begin
        example.run
      ensure
        @server.stop
      end
    end
  end

  def client
    described_class.new(server: @server.url)
  end

  describe "#list_blobs" do
    it "returns an empty hash when the store is empty" do
      expect(client.list_blobs).to eq({})
    end

    it "maps each key to its sha256" do
      body = "hello"
      client.put_blob("greeting.txt", body)

      expect(client.list_blobs).to eq("greeting.txt" => Digest::SHA256.hexdigest(body))
    end

    it "includes nested keys using POSIX-style paths" do
      client.put_blob("docs/readme.txt", "nested")

      expect(client.list_blobs.keys).to eq(["docs/readme.txt"])
    end
  end

  describe "#list_blobs_with_metadata" do
    it "returns an empty hash when the store is empty" do
      expect(client.list_blobs_with_metadata).to eq({})
    end

    it "maps each key to its full BlobMeta, including modified_at" do
      body = "hello"
      client.put_blob("greeting.txt", body)

      meta = client.list_blobs_with_metadata.fetch("greeting.txt")

      expect(meta["key"]).to eq("greeting.txt")
      expect(meta["sha256"]).to eq(Digest::SHA256.hexdigest(body))
      expect(meta["size"]).to eq(body.bytesize)
      expect(meta["modified_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end
  end

  describe "#put_blob" do
    it "uploads the body and returns key, sha256 and size" do
      body = "content"

      result = client.put_blob("file.txt", body)

      expect(result).to eq(
        "key" => "file.txt",
        "sha256" => Digest::SHA256.hexdigest(body),
        "size" => body.bytesize
      )
      expect(File.binread(File.join(@data_dir, "file.txt"))).to eq(body)
    end

    it "round-trips binary content" do
      body = (0..255).to_a.pack("C*")

      client.put_blob("binary.bin", body)

      expect(File.binread(File.join(@data_dir, "binary.bin"))).to eq(body)
    end

    it "percent-encodes special characters within a path segment without touching the '/' separators" do
      body = "spaced"

      client.put_blob("a dir/file name.bin", body)

      expect(File.binread(File.join(@data_dir, "a dir", "file name.bin"))).to eq(body)
    end

    it "raises ServerError when the server rejects the request" do
      expect { client.put_blob("", "x") }.to raise_error(Syncbox::Client::ServerError, /400/)
    end
  end

  describe "#get_blob" do
    it "returns the exact bytes previously stored" do
      body = "content"
      client.put_blob("file.txt", body)

      expect(client.get_blob("file.txt")).to eq(body)
    end

    it "round-trips binary content" do
      body = (0..255).to_a.pack("C*")
      client.put_blob("binary.bin", body)

      expect(client.get_blob("binary.bin")).to eq(body)
    end

    it "downloads a key nested under subdirectories" do
      client.put_blob("docs/readme.txt", "nested")

      expect(client.get_blob("docs/readme.txt")).to eq("nested")
    end

    it "raises ServerError when the key does not exist" do
      expect { client.get_blob("missing.txt") }.to raise_error(Syncbox::Client::ServerError, /404/)
    end
  end

  describe "connection failures" do
    it "raises ConnectionError when nothing is listening at the given URL" do
      @server.stop
      unreachable = described_class.new(server: @server.url)

      expect { unreachable.list_blobs }.to raise_error(Syncbox::Client::ConnectionError, /cannot reach server/)
    end
  end
end
