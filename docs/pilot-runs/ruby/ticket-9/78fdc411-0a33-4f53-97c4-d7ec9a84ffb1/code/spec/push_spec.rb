require "tmpdir"
require "fileutils"
require "digest"
require "stringio"
require_relative "../client/config"
require_relative "../client/server_client"
require_relative "../client/push"

RSpec.describe Syncbox::Push do
  around do |example|
    Dir.mktmpdir("syncbox-push-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def write_file(relative, content)
    path = File.join(@dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def config
    Syncbox::ClientConfig.new(command: "push", dir: @dir, server: "http://example.test:8080")
  end

  def stub_blobs_list(entries)
    stub_request(:get, "http://example.test:8080/blobs").to_return(status: 200, body: entries.to_json)
  end

  def run_push
    described_class.run(config, out: StringIO.new, err: StringIO.new)
  end

  it "uploads a file that does not exist on the server" do
    write_file("new.txt", "hello")
    stub_blobs_list([])
    put_stub = stub_request(:put, "http://example.test:8080/blobs/new.txt")
      .with(body: "hello")
      .to_return(status: 201, body: {"key" => "new.txt", "sha256" => Digest::SHA256.hexdigest("hello"), "size" => 5}.to_json)

    expect(run_push).to eq(0)
    expect(put_stub).to have_been_requested
  end

  it "uploads a file whose content differs from the server's version" do
    write_file("changed.txt", "new-content")
    stub_blobs_list([{
      "key" => "changed.txt", "size" => 3,
      "sha256" => Digest::SHA256.hexdigest("old"), "modified_at" => "2020-01-01T00:00:00Z",
    }])
    put_stub = stub_request(:put, "http://example.test:8080/blobs/changed.txt")
      .with(body: "new-content")
      .to_return(status: 201, body: "{}")

    expect(run_push).to eq(0)
    expect(put_stub).to have_been_requested
  end

  it "does not re-upload a file identical to the server's version" do
    write_file("same.txt", "identical")
    stub_blobs_list([{
      "key" => "same.txt", "size" => 9,
      "sha256" => Digest::SHA256.hexdigest("identical"), "modified_at" => "2020-01-01T00:00:00Z",
    }])

    expect(run_push).to eq(0)
    expect(WebMock).not_to have_requested(:put, "http://example.test:8080/blobs/same.txt")
  end

  it "uses the relative POSIX path within <dir> as the key, including nested directories" do
    write_file("a/b/c.txt", "nested")
    stub_blobs_list([])
    put_stub = stub_request(:put, "http://example.test:8080/blobs/a/b/c.txt").to_return(status: 201, body: "{}")

    expect(run_push).to eq(0)
    expect(put_stub).to have_been_requested
  end

  it "uploads missing files but skips unchanged ones within the same run" do
    write_file("keep.txt", "keep-me")
    write_file("upload.txt", "upload-me")
    stub_blobs_list([{
      "key" => "keep.txt", "size" => 7,
      "sha256" => Digest::SHA256.hexdigest("keep-me"), "modified_at" => "2020-01-01T00:00:00Z",
    }])
    put_stub = stub_request(:put, "http://example.test:8080/blobs/upload.txt").to_return(status: 201, body: "{}")

    expect(run_push).to eq(0)
    expect(put_stub).to have_been_requested
    expect(WebMock).not_to have_requested(:put, "http://example.test:8080/blobs/keep.txt")
  end

  it "reports a non-zero status and a clear stderr message when the server is unreachable" do
    write_file("a.txt", "x")
    stub_request(:get, "http://example.test:8080/blobs").to_raise(Errno::ECONNREFUSED)

    err = StringIO.new
    status = described_class.run(config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
  end

  it "reports a non-zero status when <dir> does not exist" do
    missing = File.join(@dir, "does-not-exist")
    bad_config = Syncbox::ClientConfig.new(command: "push", dir: missing, server: "http://example.test:8080")

    err = StringIO.new
    status = described_class.run(bad_config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
  end
end
