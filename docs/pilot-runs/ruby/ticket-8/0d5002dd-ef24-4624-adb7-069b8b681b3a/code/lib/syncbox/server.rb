require "sinatra/base"
require "digest"
require "fileutils"
require "find"
require "json"
require "pathname"
require "securerandom"

module Sinatra
  class Request
    # Syncbox's HTTP contract has no form-encoded or multipart request
    # bodies (PUT bodies are raw bytes; other bodies are JSON), so disable
    # Rack's automatic form-body parsing entirely. Without this,
    # Rack::Request#POST — invoked by Sinatra before every route runs —
    # eagerly drains rack.input (and can raise on non-UTF-8 bytes) whenever
    # Content-Type looks like form data, which is what curl sends by default
    # for --data/--data-binary, silently emptying or crashing PUT /blobs/*.
    def POST
      {}
    end
  end
end

module Syncbox
  class Server < Sinatra::Base
    # Reserved top-level name for the scratch directory holding in-progress
    # writes. Kept inside data_dir (guaranteeing it's on the same filesystem,
    # so rename(2) into place is atomic rather than a cross-filesystem copy)
    # but excluded from the key namespace and from listings, so a client can
    # never address, list, or download a temp file — not even by guessing
    # this reserved name, and not just because temp filenames are random.
    TMP_DIR_NAME = ".syncbox-tmp"

    set :data_dir, nil
    set :show_exceptions, false
    set :raise_errors, false
    # Rack::Protection's PathTraversal middleware, on by default in Sinatra,
    # silently rewrites PATH_INFO to strip ".." segments before routing even
    # runs — so a traversal attempt never reaches /blobs/* at all and either
    # 404s (route no longer matches) or gets quietly rerouted, never the 400
    # the spec requires. Disable it so requests reach blob_path_for as sent,
    # where we validate and respond 400 ourselves.
    set :protection, except: :path_traversal

    get "/healthz" do
      status 200
      "ok"
    end

    get "/blobs" do
      content_type "application/json"
      status 200
      JSON.generate(list_blobs)
    end

    put "/blobs/*" do
      key = params[:splat].first
      path = blob_path_for(key)
      body = request.body.read

      write_atomically(path, body)

      content_type "application/json"
      status 201
      JSON.generate(key: key, sha256: Digest::SHA256.hexdigest(body), size: body.bytesize)
    end

    get "/blobs/*" do
      key = params[:splat].first
      path = blob_path_for(key)

      rescuing_unrepresentable_key do
        halt 404 unless File.file?(path)

        content_type "application/octet-stream"
        File.binread(path)
      end
    end

    delete "/blobs/*" do
      key = params[:splat].first
      path = blob_path_for(key)

      rescuing_unrepresentable_key do
        halt 404 unless File.file?(path)
        File.delete(path)
      end

      status 204
      ""
    end

    private

    # Writes `body` to `path` without ever exposing a partially-written file
    # at that path: the bytes land in a randomly-named file inside the
    # reserved scratch directory (same filesystem as `path`, so the final
    # rename is a single atomic metadata operation, not a copy) and only
    # then get renamed into place. A concurrent GET therefore always sees
    # either the previous complete file or the new complete file — rename(2)
    # never exposes an intermediate state. Concurrent PUTs to the same key
    # each write their own private temp file, so they can't corrupt each
    # other's bytes either; the last rename to finish wins, same as a plain
    # last-write-wins overwrite would.
    def write_atomically(path, body)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.mkdir_p(tmp_dir)

      tmp_path = File.join(tmp_dir, SecureRandom.hex(16))
      begin
        File.binwrite(tmp_path, body)
        File.rename(tmp_path, path)
      ensure
        # Covers both error paths (disk full, permission error mid-write)
        # and an aborted client connection while `request.body.read` above
        # was still filling `body` — either way nothing was renamed into
        # place, and this removes the scratch file rather than leaking it.
        File.delete(tmp_path) if File.exist?(tmp_path)
      end
    end

    def tmp_dir
      File.join(settings.data_dir, TMP_DIR_NAME)
    end

    # Resolves `key` to an absolute path guaranteed to sit strictly inside
    # settings.data_dir, halting the request with 400 otherwise. Rejects
    # `..` path segments and absolute keys directly, then — rather than
    # trusting that check alone — re-derives the path via File.expand_path
    # (lexical, no filesystem access needed since PUT targets may not exist
    # yet) and verifies containment against the resolved root. That second
    # check is what catches anything the segment scan didn't anticipate.
    def blob_path_for(key)
      halt(400, invalid_key_error) unless valid_key?(key)

      root = File.expand_path(settings.data_dir)
      candidate = File.expand_path(File.join(root, key))

      # Strict prefix match (not just candidate == root, which a key of "."
      # would produce): a key must name a file inside the root, not the
      # root directory itself.
      halt(400, invalid_key_error) unless candidate.start_with?("#{root}#{File::SEPARATOR}")

      candidate
    rescue ArgumentError
      # Raised by File.join/expand_path on keys that can't be represented
      # as a filesystem path at all (e.g. embedded null bytes).
      halt(400, invalid_key_error)
    end

    # Some keys pass blob_path_for's structural validation (well-formed
    # UTF-8, no traversal, no null byte) yet still can't be resolved on the
    # actual filesystem: long runs of combining marks or supplementary-plane
    # characters can push a path component past the filesystem's byte limit
    # (ENAMETOOLONG), and C1 controls or high Latin-1 bytes can trip a
    # locale-sensitive syscall wrapper (EILSEQ, EINVAL, or a raised
    # ArgumentError/EncodingError instead of a clean false from File.file?).
    # No blob could ever have been stored under such a key, so treating the
    # failure as "not found" is accurate and keeps the response within the
    # codes GET/DELETE are documented to return, instead of leaking a raw
    # 500 for a problem that's really about the key, not the server.
    def rescuing_unrepresentable_key
      yield
    rescue SystemCallError, ArgumentError, EncodingError
      halt 404
    end

    def valid_key?(key)
      return false if key.nil? || key.empty?
      return false unless key.valid_encoding?
      return false if key.include?("\0")
      return false if key.start_with?("/")
      return false if key == TMP_DIR_NAME || key.start_with?("#{TMP_DIR_NAME}/")

      key.split("/").none? { |segment| segment == ".." }
    end

    def invalid_key_error
      content_type "application/json"
      JSON.generate(error: "invalid key")
    end

    def list_blobs
      root = Pathname.new(settings.data_dir)
      scratch_dir = tmp_dir
      blobs = []

      Find.find(settings.data_dir) do |path|
        Find.prune if path == scratch_dir

        next if File.directory?(path)

        pathname = Pathname.new(path)
        blobs << {
          key: pathname.relative_path_from(root).to_s,
          size: pathname.size,
          sha256: Digest::SHA256.file(path).hexdigest,
          modified_at: pathname.mtime.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
      end

      blobs.sort_by { |blob| blob[:key] }
    end
  end
end
