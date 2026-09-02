require "spec_helper"
require_relative "support/test_server"
require "syncbox/client"
require "syncbox/pull"
require "tmpdir"
require "fileutils"

RSpec.describe Syncbox::Pull do
  around do |example|
    Dir.mktmpdir do |data_dir|
      Dir.mktmpdir do |local_dir|
        @data_dir = data_dir
        @local_dir = local_dir
        @server = TestServer.start(data_dir)
        begin
          example.run
        ensure
          @server.stop
        end
      end
    end
  end

  def client
    Syncbox::Client.new(server: @server.url)
  end

  def write_remote(key, content)
    client.put_blob(key, content)
  end

  def write_local(relative_path, content)
    path = File.join(@local_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def pull!
    described_class.new(client: client, dir: @local_dir).call
  end

  it "downloads every blob when the local directory is empty" do
    write_remote("top.txt", "top")
    write_remote("docs/readme.txt", "readme")

    result = pull!

    expect(result.downloaded).to eq(["docs/readme.txt", "top.txt"])
    expect(result.skipped).to eq([])
    expect(File.binread(File.join(@local_dir, "top.txt"))).to eq("top")
    expect(File.binread(File.join(@local_dir, "docs", "readme.txt"))).to eq("readme")
  end

  it "does not re-download a file whose content already matches locally" do
    write_remote("same.txt", "unchanged")
    write_local("same.txt", "unchanged")

    result = pull!

    expect(result.downloaded).to eq([])
    expect(result.skipped).to eq(["same.txt"])
  end

  it "re-downloads and overwrites a file whose local content differs from the server version" do
    write_remote("changed.txt", "new content")
    write_local("changed.txt", "old content")

    result = pull!

    expect(result.downloaded).to eq(["changed.txt"])
    expect(result.skipped).to eq([])
    expect(File.binread(File.join(@local_dir, "changed.txt"))).to eq("new content")
  end

  it "does not call get_blob for a file that already matches locally" do
    write_remote("unchanged.txt", "same")
    write_local("unchanged.txt", "same")

    spy_client = client
    allow(spy_client).to receive(:get_blob).and_call_original

    described_class.new(client: spy_client, dir: @local_dir).call

    expect(spy_client).not_to have_received(:get_blob)
  end

  it "downloads a mix of missing and changed files while skipping unchanged ones, in a single pull" do
    write_remote("unchanged.txt", "same")
    write_local("unchanged.txt", "same")
    write_remote("changed.txt", "after")
    write_local("changed.txt", "before")
    write_remote("brand-new.txt", "new")

    result = pull!

    expect(result.downloaded).to eq(["brand-new.txt", "changed.txt"])
    expect(result.skipped).to eq(["unchanged.txt"])
    expect(File.binread(File.join(@local_dir, "changed.txt"))).to eq("after")
    expect(File.binread(File.join(@local_dir, "brand-new.txt"))).to eq("new")
  end

  it "leaves local files absent from the server untouched" do
    write_local("local-only.txt", "keep me")
    write_remote("server-only.txt", "server")

    result = pull!

    expect(result.downloaded).to eq(["server-only.txt"])
    expect(File.binread(File.join(@local_dir, "local-only.txt"))).to eq("keep me")
    expect(File.exist?(File.join(@local_dir, "server-only.txt"))).to be true
  end

  it "creates missing intermediate directories for nested keys" do
    write_remote("a/b/c/deep.txt", "deep")

    pull!

    expect(File.binread(File.join(@local_dir, "a", "b", "c", "deep.txt"))).to eq("deep")
  end

  it "round-trips binary content" do
    body = (0..255).to_a.pack("C*")
    write_remote("binary.bin", body)

    pull!

    expect(File.binread(File.join(@local_dir, "binary.bin"))).to eq(body)
  end
end
