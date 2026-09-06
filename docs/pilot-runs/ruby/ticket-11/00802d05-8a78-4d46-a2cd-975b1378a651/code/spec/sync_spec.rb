require "tmpdir"
require "fileutils"
require "digest"
require "stringio"
require "time"
require_relative "../client/config"
require_relative "../client/server_client"
require_relative "../client/sync"

RSpec.describe Syncbox::Sync do
  around do |example|
    Dir.mktmpdir("syncbox-sync-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def write_file(relative, content)
    path = File.join(@dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def read_file(relative)
    File.binread(File.join(@dir, relative))
  end

  def set_mtime(relative, time)
    path = File.join(@dir, relative)
    File.utime(time, time, path)
  end

  def sha256(content)
    Digest::SHA256.hexdigest(content)
  end

  def config
    Syncbox::ClientConfig.new(command: "sync", dir: @dir, server: "http://example.test:8080")
  end

  def stub_blobs_list(entries)
    stub_request(:get, "http://example.test:8080/blobs").to_return(status: 200, body: entries.to_json)
  end

  def run_sync
    described_class.run(config, out: StringIO.new, err: StringIO.new)
  end

  it "uploads a file that exists only locally" do
    write_file("new.txt", "hello")
    stub_blobs_list([])
    put_stub = stub_request(:put, "http://example.test:8080/blobs/new.txt")
      .with(body: "hello")
      .to_return(status: 201, body: "{}")

    expect(run_sync).to eq(0)
    expect(put_stub).to have_been_requested
    expect(read_file("new.txt")).to eq("hello")
  end

  it "downloads a file that exists only on the server" do
    stub_blobs_list([{
      "key" => "new.txt", "size" => 5,
      "sha256" => sha256("hello"), "modified_at" => "2020-01-01T00:00:00Z",
    }])
    get_stub = stub_request(:get, "http://example.test:8080/blobs/new.txt").to_return(status: 200, body: "hello")

    expect(run_sync).to eq(0)
    expect(get_stub).to have_been_requested
    expect(read_file("new.txt")).to eq("hello")
  end

  it "does not issue any DELETE requests" do
    write_file("local-only.txt", "keep-me")
    stub_blobs_list([{
      "key" => "server-only.txt", "size" => 5,
      "sha256" => sha256("hello"), "modified_at" => "2020-01-01T00:00:00Z",
    }])
    stub_request(:put, "http://example.test:8080/blobs/local-only.txt").to_return(status: 201, body: "{}")
    stub_request(:get, "http://example.test:8080/blobs/server-only.txt").to_return(status: 200, body: "hello")

    expect(run_sync).to eq(0)
    expect(WebMock).not_to have_requested(:delete, /.*/)
    expect(read_file("local-only.txt")).to eq("keep-me")
  end

  it "never uploads or downloads its own state file" do
    write_file("plain.txt", "content")
    stub_blobs_list([])
    stub_request(:put, "http://example.test:8080/blobs/plain.txt").to_return(status: 201, body: "{}")

    expect(run_sync).to eq(0)
    expect(File.file?(File.join(@dir, ".syncbox", "manifest.json"))).to be(true)
    expect(WebMock).not_to have_requested(:put, %r{\.syncbox})
  end

  describe "once a common state has been established" do
    before do
      write_file("f.txt", "original")
      stub_blobs_list([{
        "key" => "f.txt", "size" => 8,
        "sha256" => sha256("original"), "modified_at" => "2020-01-01T00:00:00Z",
      }])

      expect(run_sync).to eq(0)
      expect(WebMock).not_to have_requested(:put, "http://example.test:8080/blobs/f.txt")
      expect(WebMock).not_to have_requested(:get, "http://example.test:8080/blobs/f.txt")
    end

    it "uploads the local version when only the local file changed" do
      write_file("f.txt", "local-changed")
      stub_blobs_list([{
        "key" => "f.txt", "size" => 8,
        "sha256" => sha256("original"), "modified_at" => "2020-01-01T00:00:00Z",
      }])
      put_stub = stub_request(:put, "http://example.test:8080/blobs/f.txt")
        .with(body: "local-changed")
        .to_return(status: 201, body: "{}")

      expect(run_sync).to eq(0)
      expect(put_stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, "http://example.test:8080/blobs/f.txt")
      expect(read_file("f.txt")).to eq("local-changed")
    end

    it "downloads the server version when only the server file changed" do
      stub_blobs_list([{
        "key" => "f.txt", "size" => 14,
        "sha256" => sha256("remote-changed"), "modified_at" => "2020-06-01T00:00:00Z",
      }])
      get_stub = stub_request(:get, "http://example.test:8080/blobs/f.txt")
        .to_return(status: 200, body: "remote-changed")

      expect(run_sync).to eq(0)
      expect(get_stub).to have_been_requested
      expect(WebMock).not_to have_requested(:put, "http://example.test:8080/blobs/f.txt")
      expect(read_file("f.txt")).to eq("remote-changed")
    end

    it "resolves a conflict in favor of the more recently modified server version" do
      write_file("f.txt", "local-changed")
      set_mtime("f.txt", Time.utc(2021, 1, 1, 10, 0, 0))
      stub_blobs_list([{
        "key" => "f.txt", "size" => 15,
        "sha256" => sha256("remote-changed"), "modified_at" => "2021-01-01T12:00:00Z",
      }])
      get_stub = stub_request(:get, "http://example.test:8080/blobs/f.txt")
        .to_return(status: 200, body: "remote-changed")

      expect(run_sync).to eq(0)
      expect(get_stub).to have_been_requested
      expect(WebMock).not_to have_requested(:put, "http://example.test:8080/blobs/f.txt")
      expect(read_file("f.txt")).to eq("remote-changed")
    end

    it "resolves a conflict in favor of the more recently modified local version" do
      write_file("f.txt", "local-changed")
      set_mtime("f.txt", Time.utc(2021, 6, 1, 0, 0, 0))
      stub_blobs_list([{
        "key" => "f.txt", "size" => 15,
        "sha256" => sha256("remote-changed"), "modified_at" => "2021-01-01T00:00:00Z",
      }])
      put_stub = stub_request(:put, "http://example.test:8080/blobs/f.txt")
        .with(body: "local-changed")
        .to_return(status: 201, body: "{}")

      expect(run_sync).to eq(0)
      expect(put_stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, "http://example.test:8080/blobs/f.txt")
      expect(read_file("f.txt")).to eq("local-changed")
    end

    it "resolves a conflict with equal modified times in favor of the local version" do
      tie = Time.utc(2021, 3, 1, 0, 0, 0)
      write_file("f.txt", "local-tie")
      set_mtime("f.txt", tie)
      stub_blobs_list([{
        "key" => "f.txt", "size" => 11,
        "sha256" => sha256("remote-tie"), "modified_at" => tie.iso8601,
      }])
      put_stub = stub_request(:put, "http://example.test:8080/blobs/f.txt")
        .with(body: "local-tie")
        .to_return(status: 201, body: "{}")

      expect(run_sync).to eq(0)
      expect(put_stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, "http://example.test:8080/blobs/f.txt")
      expect(read_file("f.txt")).to eq("local-tie")
    end
  end

  it "reports a non-zero status and a clear stderr message when the server is unreachable" do
    write_file("a.txt", "x")
    stub_request(:get, "http://example.test:8080/blobs").to_raise(Errno::ECONNREFUSED)

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
  end

  it "reports a non-zero status and a clear stderr message when the server times out, without hanging" do
    write_file("a.txt", "x")
    stub_request(:get, "http://example.test:8080/blobs").to_timeout

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).to match(/timed out/)
  end

  it "pushes the other files and reports the failed one when the server returns 5xx for a single upload" do
    write_file("good.txt", "hello")
    write_file("bad.txt", "world")
    stub_blobs_list([])
    good_stub = stub_request(:put, "http://example.test:8080/blobs/good.txt").to_return(status: 201, body: "{}")
    stub_request(:put, "http://example.test:8080/blobs/bad.txt").to_return(status: 503, body: "unavailable")

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(good_stub).to have_been_requested
    expect(err.string).to include("bad.txt")
  end

  it "pulls the other files and reports the failed one when a single download fails with a network error" do
    stub_blobs_list([
      {"key" => "good.txt", "size" => 5, "sha256" => sha256("hello"), "modified_at" => "2020-01-01T00:00:00Z"},
      {"key" => "bad.txt", "size" => 5, "sha256" => sha256("world"), "modified_at" => "2020-01-01T00:00:00Z"},
    ])
    good_stub = stub_request(:get, "http://example.test:8080/blobs/good.txt").to_return(status: 200, body: "hello")
    stub_request(:get, "http://example.test:8080/blobs/bad.txt").to_timeout

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(good_stub).to have_been_requested
    expect(read_file("good.txt")).to eq("hello")
    expect(err.string).to include("bad.txt")
  end

  it "reports a non-zero status when <dir> does not exist" do
    missing = File.join(@dir, "does-not-exist")
    bad_config = Syncbox::ClientConfig.new(command: "sync", dir: missing, server: "http://example.test:8080")

    err = StringIO.new
    status = described_class.run(bad_config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
  end
end

RSpec.describe "Syncbox::Sync.classify" do
  def classify(local_sha:, remote_sha:, base_sha:, local_mtime: nil, remote_modified_at: nil)
    Syncbox::Sync.classify(
      local_sha: local_sha, remote_sha: remote_sha, base_sha: base_sha,
      local_mtime: local_mtime, remote_modified_at: remote_modified_at
    )
  end

  it "does nothing when the key exists on neither side" do
    expect(classify(local_sha: nil, remote_sha: nil, base_sha: nil)).to eq(:none)
  end

  it "pushes a key that exists only locally, regardless of base state" do
    expect(classify(local_sha: "a", remote_sha: nil, base_sha: nil)).to eq(:push)
    expect(classify(local_sha: "a", remote_sha: nil, base_sha: "a")).to eq(:push)
  end

  it "pulls a key that exists only on the server, regardless of base state" do
    expect(classify(local_sha: nil, remote_sha: "a", base_sha: nil)).to eq(:pull)
    expect(classify(local_sha: nil, remote_sha: "a", base_sha: "a")).to eq(:pull)
  end

  it "is unchanged when both sides agree" do
    expect(classify(local_sha: "a", remote_sha: "a", base_sha: nil)).to eq(:unchanged)
  end

  it "pushes when only the local side moved away from the common base" do
    expect(classify(local_sha: "b", remote_sha: "a", base_sha: "a")).to eq(:push)
  end

  it "pulls when only the server side moved away from the common base" do
    expect(classify(local_sha: "a", remote_sha: "b", base_sha: "a")).to eq(:pull)
  end

  it "falls back to the mtime rule on a true conflict (both sides moved)" do
    older = Time.utc(2020, 1, 1)
    newer = Time.utc(2020, 6, 1)

    expect(classify(
      local_sha: "b", remote_sha: "c", base_sha: "a",
      local_mtime: newer, remote_modified_at: older.iso8601
    )).to eq(:push)

    expect(classify(
      local_sha: "b", remote_sha: "c", base_sha: "a",
      local_mtime: older, remote_modified_at: newer.iso8601
    )).to eq(:pull)
  end

  it "falls back to the mtime rule when there is no common base at all" do
    older = Time.utc(2020, 1, 1)
    newer = Time.utc(2020, 6, 1)

    expect(classify(
      local_sha: "b", remote_sha: "c", base_sha: nil,
      local_mtime: older, remote_modified_at: newer.iso8601
    )).to eq(:pull)
  end

  it "favors the local version when mtimes are equal" do
    tie = Time.utc(2020, 1, 1)

    expect(classify(
      local_sha: "b", remote_sha: "c", base_sha: "a",
      local_mtime: tie, remote_modified_at: tie.iso8601
    )).to eq(:push)
  end
end
