require "sinatra/base"
require "digest"
require "fileutils"
require "json"

module Syncbox
  class Server < Sinatra::Base
    set :data_dir, nil
    set :show_exceptions, false
    set :raise_errors, false

    get "/healthz" do
      status 200
      "ok"
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
  end
end
