require "tmpdir"
require "fileutils"
require "digest"
require "stringio"
require_relative "../client/config"
require_relative "../client/server_client"
require_relative "../client/pull"

RSpec.describe Syncbox::Pull do
  around do |example|
    Dir.mktmpdir("syncbox-pull-spec") do |dir|
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

  def config
    Syncbox::ClientConfig.new(command: "pull", dir: @dir, server: "http://example.test:8080")
  end

  def stub_blobs_list(entries)
    stub_request(:get, "http://example.test:8080/blobs").to_return(status: 200, body: entries.to_json)
  end

  def run_pull
    described_class.run(config, out: StringIO.new, err: StringIO.new)
  end

  it "downloads a blob that does not exist locally" do
    stub_blobs_list([{
      "key" => "new.txt", "size" => 5,
      "sha256" => Digest::SHA256.hexdigest("hello"), "modified_at" => "2020-01-01T00:00:00Z",
    }])
    get_stub = stub_request(:get, "http://example.test:8080/blobs/new.txt").to_return(status: 200, body: "hello")

    expect(run_pull).to eq(0)
    expect(get_stub).to have_been_requested
    expect(read_file("new.txt")).to eq("hello")
  end

  it "downloads a blob whose content differs from the local version" do
    write_file("changed.txt", "old-content")
    stub_blobs_list([{
      "key" => "changed.txt", "size" => 11,
      "sha256" => Digest::SHA256.hexdigest("new-content"), "modified_at" => "2020-01-01T00:00:00Z",
    }])
    get_stub = stub_request(:get, "http://example.test:8080/blobs/changed.txt")
      .to_return(status: 200, body: "new-content")

    expect(run_pull).to eq(0)
    expect(get_stub).to have_been_requested
    expect(read_file("changed.txt")).to eq("new-content")
  end

  it "does not re-download a file identical to the server's version" do
    write_file("same.txt", "identical")
    stub_blobs_list([{
      "key" => "same.txt", "size" => 9,
      "sha256" => Digest::SHA256.hexdigest("identical"), "modified_at" => "2020-01-01T00:00:00Z",
    }])

    expect(run_pull).to eq(0)
    expect(WebMock).not_to have_requested(:get, "http://example.test:8080/blobs/same.txt")
  end

  it "uses the key as a relative POSIX path within <dir>, creating nested directories" do
    stub_blobs_list([{
      "key" => "a/b/c.txt", "size" => 6,
      "sha256" => Digest::SHA256.hexdigest("nested"), "modified_at" => "2020-01-01T00:00:00Z",
    }])
    stub_request(:get, "http://example.test:8080/blobs/a/b/c.txt").to_return(status: 200, body: "nested")

    expect(run_pull).to eq(0)
    expect(read_file("a/b/c.txt")).to eq("nested")
  end

  it "downloads missing/changed files but skips unchanged ones within the same run" do
    write_file("keep.txt", "keep-me")
    stub_blobs_list([
      {"key" => "keep.txt", "size" => 7, "sha256" => Digest::SHA256.hexdigest("keep-me"), "modified_at" => "2020-01-01T00:00:00Z"},
      {"key" => "download.txt", "size" => 11, "sha256" => Digest::SHA256.hexdigest("download-me"), "modified_at" => "2020-01-01T00:00:00Z"},
    ])
    get_stub = stub_request(:get, "http://example.test:8080/blobs/download.txt")
      .to_return(status: 200, body: "download-me")

    expect(run_pull).to eq(0)
    expect(get_stub).to have_been_requested
    expect(WebMock).not_to have_requested(:get, "http://example.test:8080/blobs/keep.txt")
    expect(read_file("download.txt")).to eq("download-me")
  end

  it "does not delete local files absent from the server" do
    write_file("local-only.txt", "keep-me-around")
    stub_blobs_list([])

    expect(run_pull).to eq(0)
    expect(read_file("local-only.txt")).to eq("keep-me-around")
  end

  it "reports a non-zero status and a clear stderr message when the server is unreachable" do
    stub_request(:get, "http://example.test:8080/blobs").to_raise(Errno::ECONNREFUSED)

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
  end

  it "reports a non-zero status and a clear stderr message when the server times out, without hanging" do
    stub_request(:get, "http://example.test:8080/blobs").to_timeout

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).to match(/timed out/)
  end

  it "downloads the other files and reports the failed one when the server returns 5xx for a single key" do
    stub_blobs_list([
      {"key" => "good.txt", "size" => 5, "sha256" => Digest::SHA256.hexdigest("hello"), "modified_at" => "2020-01-01T00:00:00Z"},
      {"key" => "bad.txt", "size" => 5, "sha256" => Digest::SHA256.hexdigest("world"), "modified_at" => "2020-01-01T00:00:00Z"},
    ])
    good_stub = stub_request(:get, "http://example.test:8080/blobs/good.txt").to_return(status: 200, body: "hello")
    stub_request(:get, "http://example.test:8080/blobs/bad.txt").to_return(status: 503, body: "unavailable")

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(good_stub).to have_been_requested
    expect(read_file("good.txt")).to eq("hello")
    expect(File.exist?(File.join(@dir, "bad.txt"))).to be(false)
    expect(err.string).to include("bad.txt")
  end

  it "downloads the other files and reports the failed one when a single GET fails with a network error" do
    stub_blobs_list([
      {"key" => "good.txt", "size" => 5, "sha256" => Digest::SHA256.hexdigest("hello"), "modified_at" => "2020-01-01T00:00:00Z"},
      {"key" => "bad.txt", "size" => 5, "sha256" => Digest::SHA256.hexdigest("world"), "modified_at" => "2020-01-01T00:00:00Z"},
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
    bad_config = Syncbox::ClientConfig.new(command: "pull", dir: missing, server: "http://example.test:8080")

    err = StringIO.new
    status = described_class.run(bad_config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
  end
end
