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
      path = File.join(settings.data_dir, key)
      FileUtils.mkdir_p(File.dirname(path))

      body = request.body.read
      File.binwrite(path, body)

      content_type "application/json"
      status 201
      JSON.generate(key: key, sha256: Digest::SHA256.hexdigest(body), size: body.bytesize)
    end

    get "/blobs/*" do
      key = params[:splat].first
      path = File.join(settings.data_dir, key)

      halt 404 unless File.file?(path)

      content_type "application/octet-stream"
      File.binread(path)
    end

    delete "/blobs/*" do
      key = params[:splat].first
      path = File.join(settings.data_dir, key)

      halt 404 unless File.file?(path)

      File.delete(path)

      status 204
      ""
    end

    private

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
