# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "stringio"
require "rack/lint"
require "rack/test"

# Lets a test run code in place of File.rename on the current thread.
module RenameInterception
  def rename(from, to)
    hook = Thread.current[:syncbox_rename_hook]
    hook ? hook.call(from, to) { super } : super
  end
end
File.singleton_class.prepend(RenameInterception)

# PUT writes to a staging file and renames it into place: readers see the old
# blob or the new one, never a partial write, and staging files never outlive
# the request or show up as blobs.
class AtomicPutTest < Minitest::Test
  include Rack::Test::Methods

  BODY_SIZE = 5 * Syncbox::Server::Store::CHUNK_SIZE + 123

  # Request body handed out in small pieces, letting other threads run (or a
  # callback look at the store) between them.
  class TrickleIO
    def initialize(data, piece: 4096, on_read: nil)
      @io = StringIO.new(data)
      @piece = piece
      @on_read = on_read
      @reads = 0
    end

    def read(length = nil, buffer = nil)
      @on_read&.call(@reads += 1)
      Thread.pass
      @io.read([length || @piece, @piece].min, buffer)
    end
  end

  # Request body that fails after some bytes, like a client that went away.
  class BrokenIO
    def initialize(data, fail_after:)
      @io = StringIO.new(data)
      @left = fail_after
    end

    def read(length, buffer = nil)
      raise EOFError, "client disconnected" if @left <= 0

      chunk = @io.read([length, @left].min, buffer)
      @left -= chunk.bytesize
      chunk
    end
  end

  def setup
    @root = Dir.mktmpdir
    @data_dir = File.join(@root, "data")
    @blobs_dir = File.join(@data_dir, "blobs")
    @tmp_dir = File.join(@data_dir, "tmp")
    Dir.mkdir(@data_dir)
    @store = Syncbox::Server::Store.new(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def app
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080)
    Rack::Lint.new(Syncbox::Server::Runner.build_app(config))
  end

  def test_concurrent_puts_to_one_key_never_expose_a_partial_blob
    versions = Array.new(6) { |i| version(i) }
    valid = versions.to_h { |v| [Digest::SHA256.hexdigest(v), v.bytesize] }
    @store.put("hot/blob", StringIO.new(versions.first))

    writers = versions.each_slice(2).map do |pair|
      Thread.new { 10.times { |i| @store.put("hot/blob", TrickleIO.new(pair[i % 2])) } }
    end
    seen = check_readers_while(writers) do
      data = read_blob("hot/blob")
      sha256 = Digest::SHA256.hexdigest(data)
      assert_equal valid[sha256], data.bytesize, "GET saw a partial or mixed blob"
      @store.list.each do |entry|
        assert_equal valid[entry[:sha256]], entry[:size], "listing saw a partial or mixed blob"
      end
      sha256
    end

    assert_operator seen.uniq.size, :>, 1, "readers should have seen the blob change"
    assert_includes versions.map { |v| sha(v) }, sha(read_blob("hot/blob"))
    assert_staging_empty
  end

  def test_concurrent_puts_to_one_key_each_report_their_own_body
    versions = Array.new(8) { |i| version(i) }
    results = versions.map { |v| Thread.new { @store.put("same", TrickleIO.new(v)) } }.map(&:value)

    assert_equal versions.map { |v| [Digest::SHA256.hexdigest(v), v.bytesize] }, results.map { |r| r.values_at(:sha256, :size) }
    assert_includes versions.map { |v| sha(v) }, sha(read_blob("same"))
    assert_equal ["same"], @store.list.map { |e| e[:key] }
    assert_staging_empty
  end

  def test_concurrent_puts_to_different_keys_do_not_interfere
    keys = Array.new(16) { |i| i.even? ? "dir/shared/#{i}" : "solo-#{i}/f" }
    bodies = keys.each_with_index.to_h { |key, i| [key, version(i, size: BODY_SIZE + i)] }

    threads = keys.map do |key|
      Thread.new { 3.times { @store.put(key, TrickleIO.new(bodies[key])) } }
    end
    threads.each(&:join)

    keys.each { |key| assert_equal sha(bodies[key]), sha(read_blob(key)), key }
    listed = @store.list.to_h { |e| [e[:key], e.values_at(:size, :sha256)] }
    assert_equal bodies.transform_values { |b| [b.bytesize, Digest::SHA256.hexdigest(b)] }, listed
    assert_staging_empty
  end

  def test_concurrent_http_puts_to_one_key_and_gets
    versions = Array.new(4) { |i| version(i) }
    put "/blobs/k", versions.first

    writers = versions.map do |v|
      Thread.new do
        session = Rack::Test::Session.new(app)
        5.times do
          session.put "/blobs/k", v
          assert_equal 201, session.last_response.status
        end
      end
    end
    reader = Rack::Test::Session.new(app)
    check_readers_while(writers) do
      reader.get "/blobs/k"
      assert_equal 200, reader.last_response.status
      assert_includes versions.map { |v| sha(v) }, sha(reader.last_response.body), "GET saw a partial or mixed blob"
    end
    assert_staging_empty
  end

  def test_upload_in_progress_is_invisible
    @store.put("docs/old", StringIO.new("old contents"))
    assert_invisible_while_staged("docs/new", version(1), before: nil)
    assert_invisible_while_staged("docs/old", version(2), before: "old contents")
    assert_invisible_while_staged("fresh/dir/blob", version(3), before: nil)
    assert_staging_empty
  end

  def test_failed_upload_keeps_old_blob_and_leaves_nothing_behind
    @store.put("a/b", StringIO.new("old"))

    assert_raises(EOFError) { @store.put("a/b", BrokenIO.new(version(1), fail_after: 100_000)) }
    assert_raises(EOFError) { @store.put("new/dir/c", BrokenIO.new(version(1), fail_after: 1)) }
    assert_raises(EOFError) { @store.put("empty", BrokenIO.new("", fail_after: 0)) }

    assert_equal "old", read_blob("a/b")
    assert_equal ["a/b"], @store.list.map { |e| e[:key] }
    assert_equal ["a"], Dir.children(@blobs_dir), "no directories for the failed keys"
    assert_staging_empty
  end

  def test_failed_rename_leaves_nothing_behind
    @store.put("a", StringIO.new("old"))
    with_rename_hook(->(_from, _to) { raise Errno::ENOSPC }) do
      assert_raises(Errno::ENOSPC) { @store.put("a", StringIO.new("new")) }
    end
    assert_equal "old", read_blob("a")
    assert_staging_empty
  end

  def test_rejected_put_leaves_no_staging_file
    put "/blobs/dir/file", "x"
    put "/blobs/dir", version(1) # a directory is in the way
    assert_equal 400, last_response.status
    put "/blobs/dir/file/below", version(1) # a file is in the way
    assert_equal 400, last_response.status
    assert_staging_empty
  end

  def test_staging_file_cannot_be_reached_as_a_blob
    FileUtils.mkdir_p(@tmp_dir)
    File.write(File.join(@tmp_dir, "abc.part"), "partial")
    ["../tmp/abc.part", "%2E%2E/tmp/abc.part", "..%2Ftmp%2Fabc.part"].each do |key|
      get "/blobs/placeholder", {}, "PATH_INFO" => "/blobs/#{key}"
      assert_equal 400, last_response.status, key
    end
    %w[tmp/abc.part abc.part].each do |key|
      get "/blobs/#{key}"
      assert_equal 404, last_response.status, key
    end
    get "/blobs"
    assert_equal [], JSON.parse(last_response.body)
  end

  def test_staging_dir_lies_next_to_the_blobs_dir
    @store.prepare!
    assert_equal File.stat(@blobs_dir).dev, File.stat(@tmp_dir).dev
    staged = nil
    with_rename_hook(->(from, _to, &rename) { staged = from; rename.call }) { @store.put("x/y", StringIO.new("z")) }
    assert_equal File.realpath(@tmp_dir), File.realpath(File.dirname(staged))
  end

  def test_prepare_removes_leftover_staging_files_only
    FileUtils.mkdir_p(@tmp_dir)
    File.write(File.join(@tmp_dir, "0123abcd.part"), "partial")
    File.write(File.join(@tmp_dir, "\xFF.part".b), "partial")
    File.write(File.join(@tmp_dir, "notes.txt"), "not ours")
    @store.put("keep", StringIO.new("x"))

    @store.prepare!

    assert_equal ["notes.txt"], Dir.children(@tmp_dir)
    assert_equal ["keep"], Dir.children(@blobs_dir), "rename probe must not be left in the store"
    assert_equal "x", read_blob("keep")
  end

  def test_prepare_data_dir_fails_when_staging_cannot_be_renamed_into_store
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080)
    error = with_rename_hook(->(_from, _to) { raise Errno::EXDEV }) do
      assert_raises(Syncbox::Server::ConfigError) { config.prepare_data_dir! }
    end
    assert_match(/same filesystem/, error.message)
    assert_equal [], Dir.children(@tmp_dir)
    assert_equal [], Dir.children(@blobs_dir)
  end

  private

  # Distinct contents per i, each spanning several read chunks; a mix of two
  # versions or a truncated one never hashes like a whole version.
  def version(i, size: BODY_SIZE)
    Random.new(i).bytes(size)
  end

  def sha(data)
    Digest::SHA256.hexdigest(data)
  end

  def read_blob(key)
    file = @store.open(key)
    assert file, "blob #{key.inspect} should exist"
    begin
      file.read.b
    ensure
      file.close
    end
  end

  # Puts body under key, checking halfway through the upload that the store
  # still shows key's previous contents (nil: none) and nothing else changed.
  def assert_invisible_while_staged(key, body, before:)
    tree = Dir.glob("**/*", base: @blobs_dir).sort
    listing = @store.list
    checked = false
    on_read = lambda do |n|
      next unless n == 3 # part of the body is on disk by now

      checked = true
      assert_equal 1, Dir.children(@tmp_dir).size, "upload should be staged in tmp/"
      before ? assert_equal(before, read_blob(key)) : assert_nil(@store.open(key))
      assert_equal listing, @store.list
      assert_equal tree, Dir.glob("**/*", base: @blobs_dir).sort, "nothing appears in the store before the rename"
    end

    @store.put(key, TrickleIO.new(body, on_read: on_read))
    assert checked
    assert_equal sha(body), sha(read_blob(key))
  end

  # Runs the block over and over until all writer threads are done; returns
  # the block's results.
  def check_readers_while(writers)
    results = []
    results << yield while writers.any?(&:alive?)
    writers.each(&:join)
    results
  end

  def with_rename_hook(hook)
    Thread.current[:syncbox_rename_hook] = hook
    yield
  ensure
    Thread.current[:syncbox_rename_hook] = nil
  end

  def assert_staging_empty
    assert_equal [], Dir.children(@tmp_dir), "staging files left behind" if File.directory?(@tmp_dir)
  end
end
