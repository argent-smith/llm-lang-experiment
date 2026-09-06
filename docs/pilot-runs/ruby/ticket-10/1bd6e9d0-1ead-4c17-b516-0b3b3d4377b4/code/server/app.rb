require "sinatra/base"
require "digest"
require "fileutils"
require "json"
require "securerandom"

module Syncbox
  class App < Sinatra::Base
    # Prefix reserved for the temp files PUT writes before the atomic rename
    # (see #resolve_blob_path/#blob_key_valid?). Any key containing a segment
    # with this prefix is rejected outright, so a temp file can never be
    # listed, read, or deleted through the public API even during the brief
    # window it exists on disk mid-upload.
    TMP_PREFIX = ".syncbox-tmp-"

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

      dir = File.dirname(path)
      tmp_path = nil
      sha256 = nil
      size = nil

      begin
        FileUtils.mkdir_p(dir)
        # Written under a reserved, publicly-unaddressable prefix and only
        # ever renamed (never edited in place), so a GET racing this PUT
        # always observes either the fully-old or fully-new content, and
        # concurrent PUTs to other keys never touch this file.
        tmp_path = File.join(dir, "#{TMP_PREFIX}#{SecureRandom.hex(16)}")
        File.binwrite(tmp_path, data)
        sha256 = Digest::SHA256.hexdigest(data)
        size = data.bytesize
        File.rename(tmp_path, path)
        tmp_path = nil
      rescue SystemCallError, ArgumentError
        halt 400
      ensure
        # Reached on success (tmp_path already nilled out above), on the
        # halt 400 above, and on any other exception (e.g. a client
        # disconnect while Sinatra is still writing the response) - in every
        # case, no temp file should be left behind.
        if tmp_path
          begin
            File.delete(tmp_path)
          rescue Errno::ENOENT
            # already gone (e.g. rename actually succeeded before raising)
          end
        end
      end

      content_type :json
      status 201
      {
        key: key,
        sha256: sha256,
        size: size,
      }.to_json
    end

    delete "/blobs/*" do
      key = params[:splat]&.first
      path = resolve_blob_path(key)
      halt 400 if path.nil?
      halt 404 unless File.file?(path)

      File.delete(path)

      status 204
      ""
    end

    # Rejects directory traversal, absolute paths, and keys that can't be
    # represented as a filesystem path (empty/"."/".." segments, invalid
    # encoding, embedded NUL) rather than any specific byte sequence. Also
    # rejects the PUT temp-file namespace (see TMP_PREFIX), so a temp file
    # can never be addressed through the public API, however it's named.
    def blob_key_valid?(key)
      return false if key.nil? || key.empty?
      return false unless key.valid_encoding?
      return false if key.include?("\u0000")

      key.split("/", -1).none? do |segment|
        segment.empty? || segment == "." || segment == ".." || segment.start_with?(TMP_PREFIX)
      end
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
