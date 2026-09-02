require "spec_helper"
require_relative "support/test_server"
require "syncbox/client"
require "syncbox/sync"
require "tmpdir"
require "fileutils"
require "time"

RSpec.describe Syncbox::Sync do
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

  def local_path(relative_path)
    File.join(@local_dir, relative_path)
  end

  def remote_path(relative_path)
    File.join(@data_dir, relative_path)
  end

  def sync!
    described_class.new(client: client, dir: @local_dir).call
  end

  it "uploads a file that exists only locally" do
    write_local("local-only.txt", "local")

    result = sync!

    expect(result.uploaded).to eq(["local-only.txt"])
    expect(result.downloaded).to eq([])
    expect(File.binread(remote_path("local-only.txt"))).to eq("local")
  end

  it "downloads a file that exists only on the server" do
    write_remote("server-only.txt", "remote")

    result = sync!

    expect(result.downloaded).to eq(["server-only.txt"])
    expect(result.uploaded).to eq([])
    expect(File.binread(local_path("server-only.txt"))).to eq("remote")
  end

  it "uploads the local version when a file changed only locally since the last sync" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common baseline for f.txt

    write_local("f.txt", "v2 local")
    result = sync!

    expect(result.uploaded).to eq(["f.txt"])
    expect(result.downloaded).to eq([])
    expect(File.binread(remote_path("f.txt"))).to eq("v2 local")
    expect(File.binread(local_path("f.txt"))).to eq("v2 local")
  end

  it "downloads the server version when a file changed only on the server since the last sync" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common baseline for f.txt

    write_remote("f.txt", "v2 server")
    result = sync!

    expect(result.downloaded).to eq(["f.txt"])
    expect(result.uploaded).to eq([])
    expect(File.binread(local_path("f.txt"))).to eq("v2 server")
    expect(File.binread(remote_path("f.txt"))).to eq("v2 server")
  end

  it "resolves a conflict (both sides changed) in favor of the newer version, even when that's remote" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common baseline for f.txt

    write_local("f.txt", "local v2")
    old_time = Time.now - 3600
    File.utime(old_time, old_time, local_path("f.txt"))
    write_remote("f.txt", "server v2") # server stamps modified_at as "now" — newer than old_time

    result = sync!

    expect(result.downloaded).to eq(["f.txt"])
    expect(result.uploaded).to eq([])
    expect(File.binread(local_path("f.txt"))).to eq("server v2")
    expect(File.binread(remote_path("f.txt"))).to eq("server v2")
  end

  it "resolves a conflict with an exactly equal mtime/modified_at in favor of local" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common baseline for f.txt

    write_remote("f.txt", "server v2")
    remote_time = Time.parse(client.list_blobs_with_metadata.fetch("f.txt").fetch("modified_at"))
    write_local("f.txt", "local v2")
    File.utime(remote_time, remote_time, local_path("f.txt"))

    result = sync!

    expect(result.uploaded).to eq(["f.txt"])
    expect(result.downloaded).to eq([])
    expect(File.binread(local_path("f.txt"))).to eq("local v2")
    expect(File.binread(remote_path("f.txt"))).to eq("local v2")
  end

  it "does not delete files present on only one side" do
    write_local("local-only.txt", "local")
    write_remote("server-only.txt", "remote")

    sync!

    expect(File.exist?(local_path("local-only.txt"))).to be true
    expect(File.exist?(remote_path("server-only.txt"))).to be true
    expect(client.list_blobs.keys).to include("local-only.txt", "server-only.txt")
  end

  it "is idempotent: a second sync of an already-synced directory transfers nothing" do
    write_local("a.txt", "a")
    write_remote("b.txt", "b")
    sync!

    result = sync!

    expect(result.uploaded).to eq([])
    expect(result.downloaded).to eq([])
    expect(result.skipped).to contain_exactly("a.txt", "b.txt")
  end

  it "never treats its own tracking manifest as a key to synchronize" do
    write_local("a.txt", "content")
    sync!

    manifest_path = local_path(described_class::MANIFEST_FILENAME)
    expect(File.exist?(manifest_path)).to be true
    expect(client.list_blobs.keys).to eq(["a.txt"])

    result = sync!

    expect(result.uploaded).to eq([])
    expect(result.downloaded).to eq([])
    expect(client.list_blobs.keys).to eq(["a.txt"])
  end
end
