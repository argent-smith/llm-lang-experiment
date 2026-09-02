require "digest"
require "find"
require "pathname"
require "fileutils"
require "json"
require "time"

module Syncbox
  # Implements `syncbox sync`: bidirectional reconciliation between a local
  # directory and the server, by POSIX-relative key and SHA-256. A key
  # present on only one side is copied to the other — exactly like push's
  # upload or pull's download. A key present on both sides with different
  # content is only a genuine conflict when *both* sides changed since the
  # last known common state; then the fixed rule from SYNCBOX-SPEC.md
  # applies: the newer modified_at/mtime wins, ties go to local. Sync never
  # deletes anything on either side.
  #
  # "Last known common state" is tracked across runs via a small JSON
  # manifest (key => sha256) that sync maintains for itself inside `dir`
  # (see MANIFEST_FILENAME) — one of the tracking strategies the spec
  # explicitly leaves to the implementation. It's excluded from `dir`'s own
  # file listing, so it's never itself treated as a key to sync.
  #
  # On the very first run there is no manifest yet, so a key that already
  # differs on both sides has no base to compare against. SYNCBOX-SPEC.md
  # notes this isn't really a "conflict" case at that point; applying the
  # same mtime rule anyway gives a sane, deterministic result without a
  # separate special case.
  class Sync
    MANIFEST_FILENAME = ".syncbox-sync-manifest.json"

    Result = Struct.new(:uploaded, :downloaded, :skipped, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
      @manifest_path = File.join(File.expand_path(@dir), MANIFEST_FILENAME)
    end

    def call
      remote = @client.list_blobs_with_metadata
      local_paths = local_files
      local_shas = local_paths.transform_values { |path| Digest::SHA256.file(path).hexdigest }
      base = load_manifest

      uploaded = []
      downloaded = []
      skipped = []
      final_shas = {}

      keys = (local_shas.keys + remote.keys).uniq.sort

      keys.each do |key|
        local_sha = local_shas[key]
        remote_sha = remote[key] && remote[key].fetch("sha256")

        if local_sha == remote_sha
          skipped << key
          final_shas[key] = local_sha
        elsif local_sha.nil?
          download(key)
          downloaded << key
          final_shas[key] = remote_sha
        elsif remote_sha.nil?
          upload(key, local_paths[key])
          uploaded << key
          final_shas[key] = local_sha
        elsif base[key] == remote_sha
          # Only the local copy changed since the last known common state.
          upload(key, local_paths[key])
          uploaded << key
          final_shas[key] = local_sha
        elsif base[key] == local_sha
          # Only the server copy changed since the last known common state.
          download(key)
          downloaded << key
          final_shas[key] = remote_sha
        elsif newer_remote?(local_paths[key], remote[key])
          download(key)
          downloaded << key
          final_shas[key] = remote_sha
        else
          upload(key, local_paths[key])
          uploaded << key
          final_shas[key] = local_sha
        end
      end

      save_manifest(final_shas)

      Result.new(uploaded: uploaded.sort, downloaded: downloaded.sort, skipped: skipped.sort)
    end

    private

    # True if the server's modified_at is strictly newer than the local
    # file's mtime — the only case where the remote version wins. Ties (and
    # any other case) resolve to local, per SYNCBOX-SPEC.md.
    def newer_remote?(local_path, remote_entry)
      Time.parse(remote_entry.fetch("modified_at")) > File.mtime(local_path)
    end

    def upload(key, path)
      @client.put_blob(key, File.binread(path))
    end

    def download(key)
      path = File.join(File.expand_path(@dir), key)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, @client.get_blob(key))
    end

    # { key => absolute path }, one entry per regular file under @dir, keyed
    # by its POSIX path relative to @dir — the same convention the server
    # uses for GET /blobs. Excludes sync's own manifest file so it's never
    # treated as user data to synchronize.
    def local_files
      root = Pathname.new(File.expand_path(@dir))
      files = {}

      Find.find(root.to_s) do |path|
        next unless File.file?(path)

        key = Pathname.new(path).relative_path_from(root).to_s
        next if key == MANIFEST_FILENAME

        files[key] = path
      end

      files
    end

    def load_manifest
      return {} unless File.file?(@manifest_path)

      JSON.parse(File.read(@manifest_path))
    rescue JSON::ParserError
      {}
    end

    def save_manifest(shas)
      File.write(@manifest_path, JSON.generate(shas))
    end
  end
end
