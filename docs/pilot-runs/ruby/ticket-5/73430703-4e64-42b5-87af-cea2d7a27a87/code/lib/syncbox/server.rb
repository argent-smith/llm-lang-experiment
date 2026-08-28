require "sinatra/base"
require "digest"
require "fileutils"
require "find"
require "json"
require "pathname"

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
      FileUtils.mkdir_p(File.dirname(path))

      body = request.body.read
      File.binwrite(path, body)

      content_type "application/json"
      status 201
      JSON.generate(key: key, sha256: Digest::SHA256.hexdigest(body), size: body.bytesize)
    end

    get "/blobs/*" do
      key = params[:splat].first
      path = blob_path_for(key)

      halt 404 unless File.file?(path)

      content_type "application/octet-stream"
      File.binread(path)
    end

    delete "/blobs/*" do
      key = params[:splat].first
      path = blob_path_for(key)

      halt 404 unless File.file?(path)

      File.delete(path)

      status 204
      ""
    end

    private

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

    def valid_key?(key)
      return false if key.nil? || key.empty?
      return false unless key.valid_encoding?
      return false if key.include?("\0")
      return false if key.start_with?("/")

      key.split("/").none? { |segment| segment == ".." }
    end

    def invalid_key_error
      content_type "application/json"
      JSON.generate(error: "invalid key")
    end

    def list_blobs
      root = Pathname.new(settings.data_dir)
      blobs = []

      Find.find(settings.data_dir) do |path|
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
