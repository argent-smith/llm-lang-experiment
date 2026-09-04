require "spec_helper"
require_relative "support/test_server"
require_relative "support/flaky_server"
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

  describe "partial failure" do
    it "still uploads the other files when the server returns 5xx for one of them" do
      write_local("good.txt", "good")
      write_local("bad.txt", "bad")
      flaky = FlakyServer.start(@data_dir, fail_on: ["PUT", "/blobs/bad.txt"])

      begin
        result = described_class.new(client: Syncbox::Client.new(server: flaky.url), dir: @local_dir).call

        expect(result.uploaded).to eq(["good.txt"])
        expect(result.failed.map(&:key)).to eq(["bad.txt"])
        expect(result.failed.first.message).to match(/500/)
        expect(File.binread(File.join(@data_dir, "good.txt"))).to eq("good")
        expect(File.exist?(File.join(@data_dir, "bad.txt"))).to be false
      ensure
        flaky.stop
      end
    end

    it "still uploads the other files when one local file can't be read" do
      write_local("good.txt", "good")
      write_local("unreadable.txt", "secret")
      bad_path = File.join(@local_dir, "unreadable.txt")
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with(bad_path).and_raise(Errno::EACCES, "permission denied")

      result = push!

      expect(result.uploaded).to eq(["good.txt"])
      expect(result.failed.map(&:key)).to eq(["unreadable.txt"])
      expect(result.failed.first.message).to include("local file error")
      expect(File.binread(File.join(@data_dir, "good.txt"))).to eq("good")
    end
  end
end
