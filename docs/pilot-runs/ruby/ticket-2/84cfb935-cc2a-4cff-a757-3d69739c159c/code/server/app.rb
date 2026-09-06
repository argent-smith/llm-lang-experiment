require "sinatra/base"
require "digest"
require "fileutils"
require "json"
require "securerandom"

module Syncbox
  class App < Sinatra::Base
    set :data_dir, nil
    # Sinatra defaults to the "development" environment (no RACK_ENV set),
    # which restricts the Host header to localhost/.test/IP addresses;
    # this server is addressed by arbitrary hostnames (docker service names,
    # rack-test's default Host header, etc.), so disable that restriction.
    set :host_authorization, {}
    # Rack::Protection's path_traversal guard silently collapses ".."/"%2e%2e"
    # segments in PATH_INFO before routing, which would route requests for
    # invalid keys away from /blobs entirely (yielding Sinatra's generic 404
    # instead of the contractual 400). blob_key_valid?/resolve_blob_path
    # below already reject traversal explicitly, so disable just this guard.
    set :protection, except: [:path_traversal]

    get "/healthz" do
      status 200
      ""
    end

    get "/blobs" do
      content_type :json
      status 200

      root = settings.data_dir
      entries = []

      if root && Dir.exist?(root)
        Dir.glob("**/*", base: root).each do |rel|
          full = File.join(root, rel)
          next unless File.file?(full)

          entries << {
            key: rel,
            size: File.size(full),
            sha256: Digest::SHA256.file(full).hexdigest,
            modified_at: File.mtime(full).utc.iso8601,
          }
        end
      end

      entries.to_json
    end

    # The OpenAPI schema models {key} as a single path segment; the real
    # contract (SYNCBOX-SPEC.md) allows a POSIX path with slashes, so this
    # route uses a splat to capture the whole remainder of the path.
    get "/blobs/*" do
      key = params[:splat]&.first
      path = resolve_blob_path(key)
      halt 400 if path.nil?
      halt 404 unless File.file?(path)

      content_type "application/octet-stream"
      File.binread(path)
    end

    put "/blobs/*" do
      key = params[:splat]&.first
      path = resolve_blob_path(key)
      halt 400 if path.nil?

      request.body.rewind
      data = request.body.read

      begin
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp_path = File.join(dir, ".syncbox-upload-#{SecureRandom.hex(8)}")
        File.binwrite(tmp_path, data)
        File.rename(tmp_path, path)
      rescue SystemCallError, ArgumentError
        halt 400
      end

      content_type :json
      status 201
      {
        key: key,
        sha256: Digest::SHA256.hexdigest(data),
        size: data.bytesize,
      }.to_json
    end

    # Rejects directory traversal, absolute paths, and keys that can't be
    # represented as a filesystem path (empty/"."/".." segments, invalid
    # encoding, embedded NUL) rather than any specific byte sequence.
    def blob_key_valid?(key)
      return false if key.nil? || key.empty?
      return false unless key.valid_encoding?
      return false if key.include?("\u0000")

      key.split("/", -1).none? { |segment| segment.empty? || segment == "." || segment == ".." }
    end

    def resolve_blob_path(key)
      return nil unless blob_key_valid?(key)

      root = File.expand_path(settings.data_dir)
      path = File.expand_path(File.join(root, key))
      return nil unless path == root || path.start_with?("#{root}#{File::SEPARATOR}")

      path
    end
  end
end
