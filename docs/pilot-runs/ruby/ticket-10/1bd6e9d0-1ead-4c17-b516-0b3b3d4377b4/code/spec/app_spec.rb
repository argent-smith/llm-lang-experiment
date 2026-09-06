require "rack/test"
require "rack/mock_request"
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

    it "rejects an absolute-looking key with 400" do
      put "/blobs//etc/passwd", "x"

      expect(last_response.status).to eq(400)
    end

    it "rejects a percent-encoded '..' segment with 400" do
      put "/blobs/%2e%2e/etc/passwd", "x"

      expect(last_response.status).to eq(400)
    end

    it "does not write outside the data directory when a traversal is attempted" do
      canary = File.join(File.dirname(Syncbox::App.settings.data_dir), "syncbox-traversal-canary.txt")

      put "/blobs/../syncbox-traversal-canary.txt", "x"

      expect(last_response.status).to eq(400)
      expect(File.exist?(canary)).to eq(false)
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

    it "rejects a key with a leading '..' segment with 400, not 404" do
      get "/blobs/../etc/passwd"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with an embedded '..' segment with 400" do
      get "/blobs/a/../../etc/passwd"

      expect(last_response.status).to eq(400)
    end

    it "rejects an absolute-looking key with 400" do
      get "/blobs//etc/passwd"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with an embedded NUL byte with 400" do
      get "/blobs/foo%00bar"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key that is not valid UTF-8 with 400" do
      get "/blobs/%ff%fe"

      expect(last_response.status).to eq(400)
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

    it "rejects a key with a leading '..' segment with 400, not 404" do
      delete "/blobs/../etc/passwd"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with an embedded '..' segment with 400" do
      delete "/blobs/a/../../etc/passwd"

      expect(last_response.status).to eq(400)
    end

    it "rejects an absolute-looking key with 400" do
      delete "/blobs//etc/passwd"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with an embedded NUL byte with 400" do
      delete "/blobs/foo%00bar"

      expect(last_response.status).to eq(400)
    end

    it "rejects a key that is not valid UTF-8 with 400" do
      delete "/blobs/%ff%fe"

      expect(last_response.status).to eq(400)
    end

    it "does not delete a file outside the data directory when a traversal is attempted" do
      outside_dir = File.dirname(Syncbox::App.settings.data_dir)
      canary = File.join(outside_dir, "syncbox-delete-canary.txt")
      File.write(canary, "do not delete me")

      begin
        delete "/blobs/../syncbox-delete-canary.txt"

        expect(last_response.status).to eq(400)
        expect(File.exist?(canary)).to eq(true)
      ensure
        File.delete(canary) if File.exist?(canary)
      end
    end
  end

  describe "atomic writes under concurrent PUT" do
    def leftover_temp_files
      Dir.glob(File.join(Syncbox::App.settings.data_dir, "**", "#{Syncbox::App::TMP_PREFIX}*"))
    end

    def stored_files
      Dir.glob(File.join(Syncbox::App.settings.data_dir, "**/*")).reject { |f| File.directory?(f) }
    end

    it "never lets a concurrent GET observe a partial or mixed write to the same key" do
      key = "race/same-key.bin"
      size = 50_000
      payloads = ["a" * size, "b" * size]
      requester = Rack::MockRequest.new(app)

      # Seed the key so readers racing the very first PUT still see full content.
      put "/blobs/#{key}", payloads.first

      observations = Queue.new
      writers = payloads.map do |payload|
        Thread.new do
          8.times { requester.put("/blobs/#{key}", input: payload) }
        end
      end
      readers = 4.times.map do
        Thread.new do
          15.times { observations << requester.get("/blobs/#{key}").body }
        end
      end
      writers.each(&:join)
      readers.each(&:join)

      expect(observations.size).to eq(60)
      until observations.empty?
        body = observations.pop
        expect(body.bytesize).to eq(size)
        expect(body).to match(/\A(a+|b+)\z/), "expected a full, uniform payload, got a mixed/partial body"
      end
    end

    it "does not let concurrent PUTs to different keys interfere with each other's content" do
      requester = Rack::MockRequest.new(app)
      count = 8

      threads = count.times.map do |i|
        Thread.new do
          content = "key-#{i}-" * 5_000
          response = requester.put("/blobs/race/key-#{i}.bin", input: content)
          [i, content, response.status]
        end
      end
      results = threads.map(&:value)

      results.each { |_, _, status| expect(status).to eq(201) }
      results.each do |i, content, _|
        get "/blobs/race/key-#{i}.bin"

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq(content)
      end
    end

    it "leaves no temp files on disk after a burst of concurrent PUTs completes" do
      requester = Rack::MockRequest.new(app)

      threads = 10.times.map do |i|
        Thread.new { requester.put("/blobs/burst/#{i}.bin", input: "x" * 1_000) }
      end
      threads.each(&:join)

      expect(leftover_temp_files).to eq([])
    end

    it "does not leave a temp file behind when the write step fails" do
      allow(File).to receive(:binwrite).and_raise(Errno::ENOSPC)

      put "/blobs/fails-write.txt", "x"

      expect(last_response.status).to eq(400)
      expect(stored_files).to eq([])
      expect(leftover_temp_files).to eq([])
    end

    it "cleans up the temp file when the final rename fails" do
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      put "/blobs/fails-rename.txt", "x"

      expect(last_response.status).to eq(400)
      expect(stored_files).to eq([])
      expect(leftover_temp_files).to eq([])
    end
  end

  describe "reserved temp-file namespace" do
    it "rejects PUT to a key under the reserved temp-file prefix with 400" do
      put "/blobs/#{Syncbox::App::TMP_PREFIX}leaked", "x"

      expect(last_response.status).to eq(400)
    end

    it "rejects GET to a key under the reserved temp-file prefix with 400, not 404" do
      get "/blobs/dir/#{Syncbox::App::TMP_PREFIX}leaked"

      expect(last_response.status).to eq(400)
    end

    it "rejects DELETE to a key under the reserved temp-file prefix with 400, not 404" do
      delete "/blobs/#{Syncbox::App::TMP_PREFIX}leaked"

      expect(last_response.status).to eq(400)
    end

    it "never lists or serves a file under the reserved prefix, even if one exists on disk" do
      leaked_path = File.join(Syncbox::App.settings.data_dir, "#{Syncbox::App::TMP_PREFIX}leaked")
      File.write(leaked_path, "leftover upload bytes")

      get "/blobs"
      expect(JSON.parse(last_response.body)).to eq([])

      get "/blobs/#{Syncbox::App::TMP_PREFIX}leaked"
      expect(last_response.status).to eq(400)
    end
  end
end
