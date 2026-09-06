require "tmpdir"
require "fileutils"
require "digest"
require "stringio"
require_relative "../client/config"
require_relative "../client/server_client"
require_relative "../client/status"

RSpec.describe Syncbox::Status do
  around do |example|
    Dir.mktmpdir("syncbox-status-spec") do |dir|
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
    Syncbox::ClientConfig.new(command: "status", dir: @dir, server: "http://example.test:8080")
  end

  def stub_blobs_list(entries)
    stub_request(:get, "http://example.test:8080/blobs").to_return(status: 200, body: entries.to_json)
  end

  def run_status(out: StringIO.new, err: StringIO.new)
    status = described_class.run(config, out: out, err: err)
    [status, out.string, err.string]
  end

  it "reports a locally-new file as something that would be uploaded, without touching the server" do
    write_file("new.txt", "hello")
    stub_blobs_list([])

    status, out, = run_status

    expect(status).to eq(0)
    expect(out).to include("would upload")
    expect(out).to include("new.txt")
    expect(out).not_to include("would download")
    expect(WebMock).not_to have_requested(:put, /.*/)
    expect(WebMock).not_to have_requested(:delete, /.*/)
  end

  it "reports a server-only file as something that would be downloaded, without touching the local filesystem" do
    stub_blobs_list([{
      "key" => "server-only.txt", "size" => 5,
      "sha256" => Digest::SHA256.hexdigest("hello"), "modified_at" => "2020-01-01T00:00:00Z",
    }])

    status, out, = run_status

    expect(status).to eq(0)
    expect(out).to include("would download")
    expect(out).to include("server-only.txt")
    expect(out).not_to include("would upload")
    expect(File.exist?(File.join(@dir, "server-only.txt"))).to be(false)
    expect(WebMock).not_to have_requested(:get, "http://example.test:8080/blobs/server-only.txt")
  end

  it "reports a file that diverged in content as both upload- and download-worthy" do
    write_file("changed.txt", "local-content")
    stub_blobs_list([{
      "key" => "changed.txt", "size" => 13,
      "sha256" => Digest::SHA256.hexdigest("remote-content"), "modified_at" => "2020-01-01T00:00:00Z",
    }])

    status, out, = run_status

    expect(status).to eq(0)
    expect(out).to include("would upload")
    expect(out).to include("would download")
    upload_section = out[/would upload.*?(?=\nwould download|\z)/m]
    download_section = out[/would download.*/m]
    expect(upload_section).to include("changed.txt")
    expect(download_section).to include("changed.txt")
    expect(read_file("changed.txt")).to eq("local-content")
  end

  it "reports no differences when local and server are identical" do
    write_file("same.txt", "identical")
    stub_blobs_list([{
      "key" => "same.txt", "size" => 9,
      "sha256" => Digest::SHA256.hexdigest("identical"), "modified_at" => "2020-01-01T00:00:00Z",
    }])

    status, out, = run_status

    expect(status).to eq(0)
    expect(out).not_to include("would upload")
    expect(out).not_to include("would download")
  end

  it "never issues PUT, DELETE, or blob-content GET requests" do
    write_file("a.txt", "aaa")
    write_file("b.txt", "bbb")
    stub_blobs_list([
      {"key" => "b.txt", "size" => 3, "sha256" => Digest::SHA256.hexdigest("different"), "modified_at" => "2020-01-01T00:00:00Z"},
      {"key" => "c.txt", "size" => 3, "sha256" => Digest::SHA256.hexdigest("ccc"), "modified_at" => "2020-01-01T00:00:00Z"},
    ])

    run_status

    expect(WebMock).not_to have_requested(:put, /.*/)
    expect(WebMock).not_to have_requested(:delete, /.*/)
    expect(WebMock).not_to have_requested(:get, %r{/blobs/.+})
    expect(File.exist?(File.join(@dir, "c.txt"))).to be(false)
    expect(read_file("a.txt")).to eq("aaa")
    expect(read_file("b.txt")).to eq("bbb")
  end

  it "returns 0 even when there are differences to report" do
    write_file("new.txt", "hello")
    stub_blobs_list([])

    status, = run_status

    expect(status).to eq(0)
  end

  it "reports a non-zero status and a clear stderr message when the server is unreachable" do
    stub_request(:get, "http://example.test:8080/blobs").to_raise(Errno::ECONNREFUSED)

    status, _out, err = run_status

    expect(status).not_to eq(0)
    expect(err).not_to be_empty
  end

  it "reports a non-zero status when <dir> does not exist" do
    missing = File.join(@dir, "does-not-exist")
    bad_config = Syncbox::ClientConfig.new(command: "status", dir: missing, server: "http://example.test:8080")

    err = StringIO.new
    status = described_class.run(bad_config, out: StringIO.new, err: err)

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
  end
end
