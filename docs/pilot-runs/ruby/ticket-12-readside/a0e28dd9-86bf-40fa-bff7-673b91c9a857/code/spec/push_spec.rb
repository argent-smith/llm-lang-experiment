require "spec_helper"
require_relative "support/test_server"
require "syncbox/client"
require "syncbox/push"
require "tmpdir"
require "fileutils"

RSpec.describe Syncbox::Push do
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

  def write_local(relative_path, content)
    path = File.join(@local_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def push!
    described_class.new(client: client, dir: @local_dir).call
  end

  it "uploads every file when the store is empty" do
    write_local("top.txt", "top")
    write_local("docs/readme.txt", "readme")

    result = push!

    expect(result.uploaded).to eq(["docs/readme.txt", "top.txt"])
    expect(result.skipped).to eq([])
    expect(File.binread(File.join(@data_dir, "top.txt"))).to eq("top")
    expect(File.binread(File.join(@data_dir, "docs", "readme.txt"))).to eq("readme")
  end

  it "does not re-upload a file whose content already matches the server" do
    write_local("same.txt", "unchanged")
    push!

    result = push!

    expect(result.uploaded).to eq([])
    expect(result.skipped).to eq(["same.txt"])
  end

  it "re-uploads a file whose content differs from the server version" do
    write_local("changed.txt", "old content")
    push!

    write_local("changed.txt", "new content")
    result = push!

    expect(result.uploaded).to eq(["changed.txt"])
    expect(result.skipped).to eq([])
    expect(File.binread(File.join(@data_dir, "changed.txt"))).to eq("new content")
  end

  it "does not call put_blob for a file that already matches the server" do
    write_local("unchanged.txt", "same")
    push!

    spy_client = client
    allow(spy_client).to receive(:put_blob).and_call_original

    described_class.new(client: spy_client, dir: @local_dir).call

    expect(spy_client).not_to have_received(:put_blob)
  end

  it "uploads a mix of new and changed files while skipping unchanged ones, in a single push" do
    write_local("unchanged.txt", "same")
    write_local("changed.txt", "before")
    push!
    write_local("changed.txt", "after")
    write_local("brand-new.txt", "new")

    result = push!

    expect(result.uploaded).to eq(["brand-new.txt", "changed.txt"])
    expect(result.skipped).to eq(["unchanged.txt"])
  end

  it "leaves files already on the server but no longer present locally untouched" do
    write_local("keep.txt", "keep")
    push!
    File.delete(File.join(@local_dir, "keep.txt"))

    write_local("new.txt", "new")
    push!

    expect(client.list_blobs.keys).to contain_exactly("keep.txt", "new.txt")
  end
end
