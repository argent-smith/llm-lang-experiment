require "spec_helper"
require_relative "support/test_server"
require "syncbox/client"
require "syncbox/status"
require "tmpdir"
require "fileutils"

RSpec.describe Syncbox::Status do
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

  def status!(status_client = client)
    described_class.new(client: status_client, dir: @local_dir).call
  end

  it "reports no differences when both sides are empty" do
    result = status!

    expect(result.to_upload).to eq([])
    expect(result.to_download).to eq([])
    expect(result.unchanged).to eq([])
  end

  it "lists a file present only locally as to_upload" do
    write_local("local-only.txt", "local")

    result = status!

    expect(result.to_upload).to eq(["local-only.txt"])
    expect(result.to_download).to eq([])
    expect(result.unchanged).to eq([])
  end

  it "lists a file present only on the server as to_download" do
    write_remote("server-only.txt", "remote")

    result = status!

    expect(result.to_upload).to eq([])
    expect(result.to_download).to eq(["server-only.txt"])
    expect(result.unchanged).to eq([])
  end

  it "lists a file with matching content as unchanged, on neither direction" do
    write_remote("same.txt", "identical")
    write_local("same.txt", "identical")

    result = status!

    expect(result.to_upload).to eq([])
    expect(result.to_download).to eq([])
    expect(result.unchanged).to eq(["same.txt"])
  end

  it "lists a file that diverged in content as both to_upload and to_download" do
    write_remote("changed.txt", "server version")
    write_local("changed.txt", "local version")

    result = status!

    expect(result.to_upload).to eq(["changed.txt"])
    expect(result.to_download).to eq(["changed.txt"])
    expect(result.unchanged).to eq([])
  end

  it "reports a mix of new, diverged and unchanged files in a single comparison" do
    write_remote("same.txt", "same")
    write_local("same.txt", "same")
    write_remote("changed.txt", "server side")
    write_local("changed.txt", "local side")
    write_remote("server-only.txt", "remote")
    write_local("local-only.txt", "local")

    result = status!

    expect(result.to_upload).to eq(["changed.txt", "local-only.txt"])
    expect(result.to_download).to eq(["changed.txt", "server-only.txt"])
    expect(result.unchanged).to eq(["same.txt"])
  end

  it "never calls put_blob, delete_blob or get_blob against the server" do
    write_remote("changed.txt", "server side")
    write_local("changed.txt", "local side")
    write_local("local-only.txt", "local")

    spy_client = client
    allow(spy_client).to receive(:put_blob).and_call_original
    allow(spy_client).to receive(:get_blob).and_call_original

    status!(spy_client)

    expect(spy_client).not_to have_received(:put_blob)
    expect(spy_client).not_to have_received(:get_blob)
  end

  it "does not modify the local filesystem" do
    write_remote("server-only.txt", "remote")
    write_local("local-only.txt", "local")

    status!

    expect(Dir.children(@local_dir)).to eq(["local-only.txt"])
    expect(File.binread(File.join(@local_dir, "local-only.txt"))).to eq("local")
  end

  it "does not modify server-side data" do
    write_remote("server-only.txt", "remote")
    write_local("local-only.txt", "local")

    status!

    expect(client.list_blobs.keys).to eq(["server-only.txt"])
    expect(File.binread(File.join(@data_dir, "server-only.txt"))).to eq("remote")
  end

  it "still reports the other files when one local file can't be read" do
    write_local("good.txt", "good")
    write_local("unreadable.txt", "secret")
    bad_path = File.join(@local_dir, "unreadable.txt")
    allow(Digest::SHA256).to receive(:file).and_call_original
    allow(Digest::SHA256).to receive(:file).with(bad_path).and_raise(Errno::EACCES, "permission denied")

    result = status!

    expect(result.to_upload).to eq(["good.txt"])
    expect(result.failed.map(&:key)).to eq(["unreadable.txt"])
    expect(result.failed.first.message).to include("local file error")
  end
end
