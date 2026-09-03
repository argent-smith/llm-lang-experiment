require "spec_helper"
require_relative "support/test_server"
require "syncbox/client"
require "syncbox/sync"
require "syncbox/local_files"
require "tmpdir"
require "fileutils"

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

  def set_local_mtime(relative_path, epoch_seconds)
    time = Time.at(epoch_seconds)
    File.utime(time, time, File.join(@local_dir, relative_path))
  end

  def set_remote_mtime(key, epoch_seconds)
    time = Time.at(epoch_seconds)
    File.utime(time, time, File.join(@data_dir, key))
  end

  def sync!
    described_class.new(client: client, dir: @local_dir).call
  end

  it "uploads a file that exists only locally" do
    write_local("only-local.txt", "local")

    result = sync!

    expect(result.uploaded).to eq(["only-local.txt"])
    expect(result.downloaded).to eq([])
    expect(File.binread(File.join(@data_dir, "only-local.txt"))).to eq("local")
  end

  it "downloads a file that exists only on the server" do
    write_remote("only-remote.txt", "remote")

    result = sync!

    expect(result.downloaded).to eq(["only-remote.txt"])
    expect(result.uploaded).to eq([])
    expect(File.binread(File.join(@local_dir, "only-remote.txt"))).to eq("remote")
  end

  it "uploads the local version when only the local copy changed since the last sync" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common-state baseline

    write_local("f.txt", "v2 local")
    result = sync!

    expect(result.uploaded).to eq(["f.txt"])
    expect(result.downloaded).to eq([])
    expect(File.binread(File.join(@data_dir, "f.txt"))).to eq("v2 local")
    expect(File.binread(File.join(@local_dir, "f.txt"))).to eq("v2 local")
  end

  it "downloads the server version when only the server copy changed since the last sync" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common-state baseline

    write_remote("f.txt", "v2 remote")
    result = sync!

    expect(result.downloaded).to eq(["f.txt"])
    expect(result.uploaded).to eq([])
    expect(File.binread(File.join(@local_dir, "f.txt"))).to eq("v2 remote")
    expect(File.binread(File.join(@data_dir, "f.txt"))).to eq("v2 remote")
  end

  it "resolves a conflict in favor of the server version when it is newer" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common-state baseline

    write_local("f.txt", "local v2")
    set_local_mtime("f.txt", 1_700_000_000)
    write_remote("f.txt", "remote v2")
    set_remote_mtime("f.txt", 1_700_000_100)

    result = sync!

    expect(result.downloaded).to eq(["f.txt"])
    expect(result.uploaded).to eq([])
    expect(File.binread(File.join(@local_dir, "f.txt"))).to eq("remote v2")
    expect(File.binread(File.join(@data_dir, "f.txt"))).to eq("remote v2")
  end

  it "resolves a conflict in favor of the local version when it is newer" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common-state baseline

    write_remote("f.txt", "remote v2")
    set_remote_mtime("f.txt", 1_700_000_000)
    write_local("f.txt", "local v2")
    set_local_mtime("f.txt", 1_700_000_100)

    result = sync!

    expect(result.uploaded).to eq(["f.txt"])
    expect(result.downloaded).to eq([])
    expect(File.binread(File.join(@local_dir, "f.txt"))).to eq("local v2")
    expect(File.binread(File.join(@data_dir, "f.txt"))).to eq("local v2")
  end

  it "resolves a conflict in favor of the local version when both mtimes are equal" do
    write_local("f.txt", "v1")
    write_remote("f.txt", "v1")
    sync! # establishes the common-state baseline

    write_local("f.txt", "local v2")
    set_local_mtime("f.txt", 1_700_000_000)
    write_remote("f.txt", "remote v2")
    set_remote_mtime("f.txt", 1_700_000_000)

    result = sync!

    expect(result.uploaded).to eq(["f.txt"])
    expect(result.downloaded).to eq([])
    expect(File.binread(File.join(@local_dir, "f.txt"))).to eq("local v2")
    expect(File.binread(File.join(@data_dir, "f.txt"))).to eq("local v2")
  end

  it "does not transfer a file whose content already matches on both sides" do
    write_local("same.txt", "identical")
    write_remote("same.txt", "identical")

    result = sync!

    expect(result.uploaded).to eq([])
    expect(result.downloaded).to eq([])
    expect(result.unchanged).to eq(["same.txt"])
  end

  it "is a no-op on a second run when nothing changed on either side" do
    write_local("a.txt", "a")
    write_remote("b.txt", "b")
    sync!

    result = sync!

    expect(result.uploaded).to eq([])
    expect(result.downloaded).to eq([])
    expect(result.unchanged).to contain_exactly("a.txt", "b.txt")
  end

  it "never deletes files missing from the other side" do
    write_local("local-only.txt", "local")
    write_remote("remote-only.txt", "remote")

    sync!
    sync!

    expect(File.exist?(File.join(@local_dir, "local-only.txt"))).to be true
    expect(File.exist?(File.join(@local_dir, "remote-only.txt"))).to be true
    expect(client.list_blobs.keys).to contain_exactly("local-only.txt", "remote-only.txt")
  end

  it "does not treat its own manifest file as a syncable blob" do
    write_local("a.txt", "a")

    sync!

    expect(client.list_blobs.keys).not_to include(Syncbox::LocalFiles::MANIFEST_FILENAME)
    expect(File.exist?(File.join(@local_dir, Syncbox::LocalFiles::MANIFEST_FILENAME))).to be true

    result = sync!
    expect(result.uploaded).to eq([])
    expect(result.downloaded).to eq([])
  end
end
