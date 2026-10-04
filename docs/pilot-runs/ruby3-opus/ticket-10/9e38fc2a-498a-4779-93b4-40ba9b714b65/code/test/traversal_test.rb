# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "rack/lint"
require "rack/test"

# Directory traversal: no key, however spelled, may make PUT, GET or DELETE
# /blobs/{key} touch anything outside <data-dir>/blobs. Keys that try are
# answered with 400 (GET/DELETE may say 404 where the key is well-formed but
# leads through a symlink); the server never fails with 500.
class TraversalTest < Minitest::Test
  include Rack::Test::Methods

  TRAVERSAL_KEYS = [
    "..", "../x", "../../etc/passwd", "a/../../x", "a/..", "a/../b",
    "%2e%2e", "%2e%2e/x", "%2E%2E%2Fx", ".%2e/x", "..%2Fx", "a%2F..%2F..%2Fx",
    "/etc/passwd", "%2Fetc%2Fpasswd", "%2F%2Fetc%2Fpasswd", "/", "%2F"
  ].freeze

  # Keys that can't be represented as a file name here: invalid or truncated
  # UTF-8 (incl. encoded surrogates and overlong "../"), NUL, broken escapes.
  UNREPRESENTABLE_KEYS = [
    "%FF", "%C3", "%ED%A0%80", "%ED%B0%80", "%ED%A0%BD%ED%B8%80",
    "%C0%AE%C0%AE/x", "%C0%AF", "%E0%80%AE%E0%80%AE%2Fx",
    "%00", "a%00b", "..%00/x",
    "%", "%z", "%zz", "a%2", "%%2e%2e"
  ].freeze

  def setup
    @root = Dir.mktmpdir
    @data_dir = File.join(@root, "data")
    @blobs_dir = File.join(@data_dir, "blobs")
    @outside = File.join(@root, "outside")
    Dir.mkdir(@data_dir)
    Dir.mkdir(@outside)
    File.write(File.join(@outside, "secret"), "outside the store")
    # Something to reach for one level above the blobs dir, too.
    File.write(File.join(@data_dir, "sibling"), "next to the store")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def app
    config = Syncbox::Server::Config.new(data_dir: @data_dir, port: 8080)
    Rack::Lint.new(Syncbox::Server::Runner.build_app(config))
  end

  def test_traversal_and_absolute_keys_are_rejected_on_every_method
    put "/blobs/a/b", "inside"
    (TRAVERSAL_KEYS + ["a/b/../../../sibling", "a/b/../../../../outside/secret"]).each do |key|
      %w[PUT GET DELETE].each do |method|
        request_raw method, "/blobs/#{key}"
        assert_equal 400, last_response.status, "#{method} #{key.inspect}"
      end
    end
    assert_untouched
    assert_equal ["a/b"], listing
  end

  def test_unrepresentable_keys_are_rejected_on_every_method
    (UNREPRESENTABLE_KEYS.map { |k| "/blobs/#{k}" } + ["/blobs/\xFF".b, "/blobs/a/\xC0\xAE\xC0\xAE".b]).each do |path|
      %w[PUT GET DELETE].each do |method|
        request_raw method, path
        assert_equal 400, last_response.status, "#{method} #{path.inspect}"
      end
    end
    assert_untouched
    assert_equal [], listing
  end

  # ".." only matters as a whole path segment; inside a name it is harmless.
  def test_dots_inside_names_are_ordinary_keys
    %w[a..b ... .hidden x/..y/z..].each do |key|
      put "/blobs/#{key}", key
      assert_equal 201, last_response.status, "PUT #{key.inspect}"
      get "/blobs/#{key}"
      assert_equal key, last_response.body
    end
    assert_equal %w[... .hidden a..b x/..y/z..], listing
  end

  # A key is never shell- or home-expanded: "~" is just a character.
  def test_tilde_keys_stay_inside_the_store
    %w[~/x ~root/x ~nosuchuser/x ~~].each do |key|
      put "/blobs/#{key}", key
      assert_equal 201, last_response.status, "PUT #{key.inspect}"
      assert_equal key, File.read(File.join(@blobs_dir, key))
    end
  end

  # A directory symlink inside the store (placed there by hand, not via the
  # API) must not let a key reach through it, in either direction.
  def test_symlinked_directory_in_store_is_not_followed
    FileUtils.mkdir_p(@blobs_dir)
    File.symlink(@outside, File.join(@blobs_dir, "link"))

    get "/blobs/link/secret"
    assert_equal 404, last_response.status
    %w[link/secret link/new link/deep/new].each do |key|
      put "/blobs/#{key}", "overwritten"
      assert_equal 400, last_response.status, "PUT #{key.inspect}"
    end
    delete "/blobs/link/secret"
    assert_equal 404, last_response.status

    assert_untouched
    assert_equal [], listing
  end

  def test_symlink_deeper_in_the_key_is_not_followed
    put "/blobs/a/b/c", "inside"
    File.symlink(@outside, File.join(@blobs_dir, "a", "b", "link"))

    get "/blobs/a/b/link/secret"
    assert_equal 404, last_response.status
    put "/blobs/a/b/link/x/y", "evil"
    assert_equal 400, last_response.status
    assert_untouched
    assert_equal ["a/b/c"], listing
  end

  # Even a symlink back into the store is refused: it would give one blob
  # two keys, and the listing (which skips symlinks) would hide one.
  def test_symlink_pointing_inside_the_store_is_not_followed
    put "/blobs/real/file", "data"
    File.symlink(File.join(@blobs_dir, "real"), File.join(@blobs_dir, "alias"))

    get "/blobs/alias/file"
    assert_equal 404, last_response.status
    put "/blobs/alias/other", "x"
    assert_equal 400, last_response.status
    assert_equal ["real/file"], listing
  end

  # The data dir itself may be reached through a symlink; that is the
  # operator's choice and must keep working.
  def test_data_dir_behind_a_symlink_works
    real = File.join(@root, "real-data")
    Dir.mkdir(real)
    linked = File.join(@root, "linked-data")
    File.symlink(real, linked)
    @data_dir = linked

    put "/blobs/docs/readme.txt", "hi"
    assert_equal 201, last_response.status
    get "/blobs/docs/readme.txt"
    assert_equal "hi", last_response.body
    delete "/blobs/docs/readme.txt"
    assert_equal 204, last_response.status
  end

  # The resolved-path check holds on its own: with the textual key checks
  # switched off, traversal keys still cannot leave the store.
  def test_store_confines_paths_without_relying_on_key_validation
    lax = Class.new(Syncbox::Server::Store) do
      def self.validate_key(key) = key.b.force_encoding(Encoding::UTF_8)
    end
    store = lax.new(@data_dir)
    store.put("seed", StringIO.new("x"))

    ["../sibling", "../../outside/secret", "a/../../sibling", "a/b/../../../sibling", "", ".", "a/..", "./"].each do |key|
      assert_raises(Syncbox::Server::InvalidKeyError, "put #{key.inspect}") { store.put(key, StringIO.new("evil")) }
      assert_raises(Syncbox::Server::InvalidKeyError, "open #{key.inspect}") { store.open(key) }
      assert_raises(Syncbox::Server::InvalidKeyError, "delete #{key.inspect}") { store.delete(key) }
    end
    assert_untouched
    assert_equal ["seed"], store.list.map { |e| e[:key] }
  end

  def test_garbage_keys_never_escape_or_crash
    rng = Random.new(5)
    alphabet = ["a", ".", "..", "/", "%2F", "%2e", "%2E%2E", "%5C", "\\", "~", "%00", "%FF",
                "%C0%AE", "%ED%A0%80", "%", "%25", "link", "sibling", "outside", "secret"]
    FileUtils.mkdir_p(@blobs_dir)
    File.symlink(@outside, File.join(@blobs_dir, "link"))
    600.times do
      key = Array.new(rng.rand(1..8)) { alphabet.sample(random: rng) }.join.b
      %w[PUT GET DELETE].each do |method|
        request_raw method, "/blobs/#{key}".b, "x"
        assert_includes({ "PUT" => [201, 400], "GET" => [200, 400, 404], "DELETE" => [204, 400, 404] }[method],
                        last_response.status, "#{method} #{key.inspect}")
      end
    end
    assert_untouched
  end

  private

  # Sends a request with an arbitrary raw path, bypassing URI parsing in rack-test.
  def request_raw(method, path, body = "x")
    params = method == "PUT" ? body : {}
    custom_request method, "/blobs/placeholder", params, "PATH_INFO" => path.b
  end

  def listing
    get "/blobs"
    assert_equal 200, last_response.status
    JSON.parse(last_response.body).map { |e| e["key"] }
  end

  # Nothing outside <data-dir>/blobs (and the staging dir) was created,
  # changed or removed.
  def assert_untouched
    assert_equal ["secret"], Dir.children(@outside)
    assert_equal "outside the store", File.read(File.join(@outside, "secret"))
    assert_equal "next to the store", File.read(File.join(@data_dir, "sibling"))
    assert_equal [], Dir.children(@data_dir) - %w[blobs tmp sibling]
    tmp = File.join(@data_dir, "tmp")
    assert_equal [], Dir.children(tmp), "staging files left behind" if File.directory?(tmp)
  end
end
