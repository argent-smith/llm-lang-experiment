require "digest"
require "fileutils"
require "time"
require_relative "local_files"
require_relative "manifest"
require_relative "client"
require_relative "failure"

module Syncbox
  # Implements `syncbox sync`: a bidirectional merge of a local directory
  # and the server's blobs by SHA-256, per the conflict-resolution rule in
  # SYNCBOX-SPEC.md.
  #
  # A per-directory Manifest records, for each key, the SHA-256 both sides
  # shared as of the last successful sync -- the "last known common state"
  # the rule is defined against. For every key present on either side:
  #
  #   - only local            -> upload (push)
  #   - only remote           -> download (pull)
  #   - both, same SHA-256    -> nothing to transfer
  #   - both, different SHA-256:
  #       - remote side unchanged since the last common state -> upload (local wins)
  #       - local side unchanged since the last common state  -> download (remote wins)
  #       - otherwise (both sides changed, or there is no recorded common
  #         state yet -- e.g. the first sync of a key that already
  #         differed on both sides) -> conflict: the newer of local mtime
  #         and remote modified_at wins; a tie goes to the local version.
  #
  # Never deletes anything on either side -- a key missing from one side
  # because it was never created there is indistinguishable from one that
  # was deleted on purpose, and the spec has sync propagate content, not
  # deletions (same as push/pull).
  #
  # A single key failing (a network error or 5xx on its request, a local
  # read/write error) doesn't abort the rest -- per SYNCBOX-SPEC.md's
  # partial-failure rule, every other key is still attempted and the
  # failure is collected into Result#failed for the caller to report. A
  # failed key's manifest entry is left untouched, since we can't record a
  # new common state for content we didn't actually manage to sync.
  class Sync
    Result = Struct.new(:uploaded, :downloaded, :unchanged, :failed, keyword_init: true)

    def initialize(client:, dir:)
      @client = client
      @dir = dir
    end

    def call
      remote_blobs = @client.list_blobs_meta
      local_paths = LocalFiles.list(@dir)
      manifest = Manifest.load(@dir)

      uploaded = []
      downloaded = []
      unchanged = []
      failed = []

      (local_paths.keys | remote_blobs.keys).each do |key|
        local_path = local_paths[key]
        local_sha = local_path && Digest::SHA256.file(local_path).hexdigest
        remote_meta = remote_blobs[key]
        remote_sha = remote_meta&.fetch(:sha256)

        case resolve(key, local_sha, remote_sha, remote_meta, manifest, local_path)
        when :upload
          @client.put_blob(key, File.binread(local_path))
          manifest[key] = local_sha
          uploaded << key
        when :download
          write_local(key, @client.get_blob(key))
          manifest[key] = remote_sha
          downloaded << key
        when :unchanged
          manifest[key] = local_sha
          unchanged << key
        end
      rescue Client::ConnectionError, Client::ServerError => e
        failed << Failure.new(key: key, message: e.message)
      rescue SystemCallError, IOError => e
        failed << Failure.new(key: key, message: "local file error: #{e.message}")
      end

      manifest.save

      Result.new(uploaded: uploaded.sort, downloaded: downloaded.sort, unchanged: unchanged.sort,
                 failed: failed.sort_by(&:key))
    end

    private

    def resolve(key, local_sha, remote_sha, remote_meta, manifest, local_path)
      return :download if local_sha.nil?
      return :upload if remote_sha.nil?
      return :unchanged if local_sha == remote_sha

      base_sha = manifest[key]
      return :download if base_sha == local_sha
      return :upload if base_sha == remote_sha

      remote_wins?(local_path, remote_meta.fetch(:modified_at)) ? :download : :upload
    end

    # "Newer wins, tie goes to local" per SYNCBOX-SPEC.md -- collapses to
    # "remote wins only if strictly newer than local".
    def remote_wins?(local_path, remote_modified_at)
      Time.iso8601(remote_modified_at).to_i > File.mtime(local_path).to_i
    end

    def write_local(key, body)
      path = File.join(File.expand_path(@dir), key)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
  end
end
