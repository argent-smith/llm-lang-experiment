require "spec_helper"
require "syncbox/server"
require "digest"
require "json"
require "tmpdir"
require "rack/mock"

RSpec.describe Syncbox::Server do
  include Rack::Test::Methods

  def app
    Syncbox::Server
  end

  # Mirrors how a real client would put an arbitrary byte string on the
  # wire: percent-encode every byte so Rack/Sinatra's own URL-decoding
  # reconstructs the exact key, the same way the existing "%2e%2e", "%FF%FE"
  # and "evil%00.txt" examples already rely on below.
  def percent_encode_key(key)
    key.b.each_byte.map { |byte| format("%%%02X", byte) }.join
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

    it "still allows filenames that merely contain '..' as a substring" do
      put "/blobs/file..txt", "content", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(201)
      expect(File.binread(File.join(@data_dir, "file..txt"))).to eq("content")
    end

    it "still allows a nested filename starting with '..'" do
      put "/blobs/a/..hidden", "content", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(201)
      expect(File.binread(File.join(@data_dir, "a", "..hidden"))).to eq("content")
    end

    [
      "../escape.txt",
      "../../etc/passwd",
      "a/../../escape.txt",
      "a/../../../escape.txt",
      "..",
      "a/..",
      "%2e%2e/escape.txt"
    ].each do |key|
      it "rejects a key of #{key.inspect} with 400 and does not write outside the store" do
        put "/blobs/#{key}", "content", { "HTTP_HOST" => "localhost" }

        expect(last_response.status).to eq(400)
        expect(File.exist?(File.join(File.dirname(@data_dir), "escape.txt"))).to be(false)
      end
    end

    it "rejects an absolute-path key with 400" do
      put "/blobs//etc/passwd", "content", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "rejects a key containing a null byte with 400 instead of raising" do
      put "/blobs/evil%00.txt", "content", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with invalid UTF-8 byte sequences after URL-decoding with 400" do
      put "/blobs/%FF%FE", "content", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "rejects an empty key with 400" do
      put "/blobs/", "content", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "does not create any file on disk when the key is rejected" do
      put "/blobs/../escape.txt", "content", { "HTTP_HOST" => "localhost" }

      expect(Dir.children(@data_dir)).to eq([])
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

    [
      "../escape.txt",
      "../../etc/passwd",
      "a/../../escape.txt",
      "..",
      "%2e%2e/escape.txt"
    ].each do |key|
      it "rejects a key of #{key.inspect} with 400" do
        get "/blobs/#{key}", {}, { "HTTP_HOST" => "localhost" }

        expect(last_response.status).to eq(400)
      end
    end

    it "rejects an absolute-path key with 400" do
      get "/blobs//etc/passwd", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "rejects a key containing a null byte with 400 instead of raising" do
      get "/blobs/evil%00.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with invalid UTF-8 byte sequences after URL-decoding with 400" do
      get "/blobs/%FF%FE", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    # These keys are well-formed UTF-8 (they pass valid_key?'s encoding and
    # traversal checks) but land on byte patterns that can make a stat/read
    # syscall on the resulting path fail outright — a C1 control character,
    # a long run of combining diacritics (can push a single path component
    # past the filesystem's NAME_MAX), a supplementary-plane character, and
    # a high Latin-1-range character. The spec allows 200, 404 or 400 for
    # GET; only a raw 500 is off the table.
    {
      "a C1 control character (U+008E)" => "e1",
      "a long run of combining diacritics" => "e1#{"́" * 200}",
      "a supplementary-plane character" => "e1\u{1F600}",
      "a high Latin-1-range character" => "e1¶"
    }.each do |description, key|
      it "never returns 500 for a key containing #{description}" do
        get "/blobs/#{percent_encode_key(key)}", {}, { "HTTP_HOST" => "localhost" }

        expect(last_response.status).not_to eq(500)
        expect([200, 400, 404]).to include(last_response.status)
      end
    end

    it "returns 404 instead of 500 when the filesystem raises while checking whether the blob exists" do
      allow(File).to receive(:file?).and_raise(Errno::ENAMETOOLONG)

      get "/blobs/some-key.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "returns 404 instead of 500 when the filesystem raises ArgumentError while checking whether the blob exists" do
      allow(File).to receive(:file?).and_raise(ArgumentError, "invalid byte sequence in path")

      get "/blobs/some-key.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "returns 404 instead of 500 when reading an existing blob's content raises at the filesystem layer" do
      put "/blobs/some-key.txt", "content", { "HTTP_HOST" => "localhost" }
      allow(File).to receive(:binread).and_raise(Errno::EILSEQ)

      get "/blobs/some-key.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "does not leak a file outside the store when given a traversal key" do
      secret_path = File.join(File.dirname(@data_dir), "syncbox-secret-#{Process.pid}.txt")
      File.write(secret_path, "top secret")

      begin
        get "/blobs/../#{File.basename(secret_path)}", {}, { "HTTP_HOST" => "localhost" }

        expect(last_response.status).to eq(400)
        expect(last_response.body).not_to include("top secret")
      ensure
        File.delete(secret_path) if File.exist?(secret_path)
      end
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

    [
      "../escape.txt",
      "../../etc/passwd",
      "a/../../escape.txt",
      "..",
      "%2e%2e/escape.txt"
    ].each do |key|
      it "rejects a key of #{key.inspect} with 400" do
        delete "/blobs/#{key}", {}, { "HTTP_HOST" => "localhost" }

        expect(last_response.status).to eq(400)
      end
    end

    it "rejects an absolute-path key with 400" do
      delete "/blobs//etc/passwd", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "rejects a key containing a null byte with 400 instead of raising" do
      delete "/blobs/evil%00.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    it "rejects a key with invalid UTF-8 byte sequences after URL-decoding with 400" do
      delete "/blobs/%FF%FE", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(400)
    end

    # Same rationale as the GET-side block above: these keys pass valid_key?
    # but land on byte patterns that can make unlink(2)/stat(2) fail outright.
    # The spec allows 204, 404 or 400 for DELETE; only a raw 500 is off the
    # table.
    {
      "a C1 control character (U+008E)" => "e1",
      "a long run of combining diacritics" => "e1#{"́" * 200}",
      "a supplementary-plane character" => "e1\u{1F600}",
      "a high Latin-1-range character" => "e1¶"
    }.each do |description, key|
      it "never returns 500 for a key containing #{description}" do
        delete "/blobs/#{percent_encode_key(key)}", {}, { "HTTP_HOST" => "localhost" }

        expect(last_response.status).not_to eq(500)
        expect([204, 400, 404]).to include(last_response.status)
      end
    end

    it "returns 404 instead of 500 when the filesystem raises while checking whether the blob exists" do
      allow(File).to receive(:file?).and_raise(Errno::ENAMETOOLONG)

      delete "/blobs/some-key.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "returns 404 instead of 500 when the filesystem raises ArgumentError while checking whether the blob exists" do
      allow(File).to receive(:file?).and_raise(ArgumentError, "invalid byte sequence in path")

      delete "/blobs/some-key.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "returns 404 instead of 500 when unlinking an existing blob raises at the filesystem layer" do
      put "/blobs/some-key.txt", "content", { "HTTP_HOST" => "localhost" }
      allow(File).to receive(:delete).and_raise(Errno::ENOENT)

      delete "/blobs/some-key.txt", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(404)
    end

    it "does not delete a file outside the store when given a traversal key" do
      secret_path = File.join(File.dirname(@data_dir), "syncbox-secret-#{Process.pid}.txt")
      File.write(secret_path, "top secret")

      begin
        delete "/blobs/../#{File.basename(secret_path)}", {}, { "HTTP_HOST" => "localhost" }

        expect(last_response.status).to eq(400)
        expect(File.exist?(secret_path)).to be(true)
      ensure
        File.delete(secret_path) if File.exist?(secret_path)
      end
    end
  end

  describe "round-tripping a legitimate key with an unusual but valid substring" do
    it "stores, retrieves and deletes a key containing an accented letter, a combining mark and an emoji without error" do
      key = "café-#{"́"}-\u{1F389}-notes.txt"
      encoded_key = percent_encode_key(key)
      body = "unusual key content"

      put "/blobs/#{encoded_key}", body, { "HTTP_HOST" => "localhost" }
      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)["key"]).to eq(key)

      get "/blobs/#{encoded_key}", {}, { "HTTP_HOST" => "localhost" }
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq(body)

      delete "/blobs/#{encoded_key}", {}, { "HTTP_HOST" => "localhost" }
      expect(last_response.status).to eq(204)

      get "/blobs/#{encoded_key}", {}, { "HTTP_HOST" => "localhost" }
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

  describe "atomicity of PUT under concurrency" do
    # Threads below issue requests directly against Rack, each through its
    # own Rack::MockRequest, rather than via Rack::Test::Methods: the latter
    # keeps `last_response` on shared instance state, which races when
    # multiple threads call it concurrently. A fresh Rack::MockRequest per
    # thread gives each call an independent, thread-safe response object.
    # HTTP_HOST is required on every call, same as elsewhere in this file:
    # Rack::Protection::HostAuthorization (on by default, not in the
    # `except:` list settings.rb disables) rejects Rack::MockRequest's
    # default Host of "example.org".
    def mock_put(key, body)
      Rack::MockRequest.new(Syncbox::Server).put("/blobs/#{key}", input: body, "HTTP_HOST" => "localhost")
    end

    def mock_get(key)
      Rack::MockRequest.new(Syncbox::Server).get("/blobs/#{key}", "HTTP_HOST" => "localhost")
    end

    # A timing-based stress test (many threads racing on a shared key, hoping
    # a reader samples a torn write) turns out not to be a reliable way to
    # catch a regression here: under MRI, per-request overhead (routing,
    # SHA-256 over the body) dominates the actual write(2) call, so even a
    # deliberately reintroduced direct File.binwrite(path, body) essentially
    # never gets caught mid-write within a test-sized time budget — verified
    # by hand against that reverted implementation before writing this test.
    # Instead, synchronize deterministically on the one moment that matters:
    # the temp file has been fully written but not yet renamed into place.
    it "keeps GET returning the previous complete blob until the temp file is renamed into place, then the new one" do
      key = "slow.bin"
      mock_put(key, "old content")

      writer_wrote_tmp_file = Queue.new
      release_rename = Queue.new

      allow(File).to receive(:binwrite).and_wrap_original do |original, tmp_path, data|
        result = original.call(tmp_path, data)
        if tmp_path.include?(Syncbox::Server::TMP_DIR_NAME)
          writer_wrote_tmp_file << true
          release_rename.pop
        end
        result
      end

      writer = Thread.new { mock_put(key, "new content") }

      unless writer_wrote_tmp_file.pop(timeout: 5)
        raise "PUT never wrote a temp file under #{Syncbox::Server::TMP_DIR_NAME} within 5s — did the atomic-write path change?"
      end

      mid_write = mock_get(key)
      expect(mid_write.status).to eq(200)
      expect(mid_write.body).to eq("old content")

      release_rename << true
      writer.join

      after_rename = mock_get(key)
      expect(after_rename.body).to eq("new content")
    end

    it "lets concurrent PUTs to different keys succeed without interfering with each other" do
      keys = (1..10).map { |i| "concurrent/key-#{i}.txt" }

      threads = keys.map do |key|
        Thread.new { mock_put(key, "content for #{key}") }
      end
      responses = threads.map(&:value)

      expect(responses.map(&:status).uniq).to eq([201])
      keys.each do |key|
        expect(File.binread(File.join(@data_dir, key))).to eq("content for #{key}")
      end
    end

    it "does not leave temp files on disk after concurrent PUTs to the same key" do
      key = "cleanup.bin"
      threads = 8.times.map do |i|
        Thread.new { mock_put(key, "version #{i}") }
      end
      threads.each(&:join)

      scratch_dir = File.join(@data_dir, Syncbox::Server::TMP_DIR_NAME)
      expect(Dir.exist?(scratch_dir) ? Dir.children(scratch_dir) : []).to eq([])
    end

    it "cleans up the temp file and leaves the previous version intact when the write fails" do
      put "/blobs/stable.txt", "original content", { "HTTP_HOST" => "localhost" }

      allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

      put "/blobs/stable.txt", "new content that never lands", { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(500)
      expect(File.binread(File.join(@data_dir, "stable.txt"))).to eq("original content")

      scratch_dir = File.join(@data_dir, Syncbox::Server::TMP_DIR_NAME)
      expect(Dir.children(scratch_dir)).to eq([])
    end

    it "excludes the scratch directory from the GET /blobs listing, even with a leftover file in it" do
      scratch_dir = File.join(@data_dir, Syncbox::Server::TMP_DIR_NAME)
      FileUtils.mkdir_p(scratch_dir)
      File.binwrite(File.join(scratch_dir, "leftover-from-a-crash"), "orphaned bytes")

      put "/blobs/real.txt", "real content", { "HTTP_HOST" => "localhost" }
      get "/blobs", {}, { "HTTP_HOST" => "localhost" }

      json = JSON.parse(last_response.body)
      expect(json.map { |b| b["key"] }).to eq(["real.txt"])
    end

    [
      Syncbox::Server::TMP_DIR_NAME,
      "#{Syncbox::Server::TMP_DIR_NAME}/leftover-from-a-crash"
    ].each do |key|
      it "rejects the reserved scratch-directory key #{key.inspect} on PUT with 400" do
        put "/blobs/#{key}", "content", { "HTTP_HOST" => "localhost" }

        expect(last_response.status).to eq(400)
      end

      it "rejects the reserved scratch-directory key #{key.inspect} on GET with 400, not a leaked file" do
        scratch_dir = File.join(@data_dir, Syncbox::Server::TMP_DIR_NAME)
        FileUtils.mkdir_p(scratch_dir)
        File.binwrite(File.join(scratch_dir, "leftover-from-a-crash"), "orphaned bytes")

        get "/blobs/#{key}", {}, { "HTTP_HOST" => "localhost" }

        expect(last_response.status).to eq(400)
      end
    end
  end
end
