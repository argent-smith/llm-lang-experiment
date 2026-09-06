require "digest"
require "pathname"
require_relative "push"

module Syncbox
  module Status
    module_function

    # Dry-run comparison of config.dir against the server's blob list: prints
    # what push would upload and what pull would download, without issuing a
    # single PUT/DELETE or touching the local filesystem. A file whose SHA-256
    # differs on both sides shows up in both lists — status doesn't apply the
    # sync conflict-resolution rule (that's a separate command), it just
    # reports what each of push and pull would independently do.
    def run(config, out: $stdout, err: $stderr)
      base = Pathname.new(config.dir)
      unless base.directory?
        err.puts "syncbox: #{config.dir}: not a directory"
        return 1
      end

      client = ServerClient.new(config.server)

      begin
        remote_sha = client.list_blobs.each_with_object({}) { |entry, h| h[entry["key"]] = entry["sha256"] }
      rescue ServerClient::ConnectionError, ServerClient::RequestError => e
        err.puts "syncbox: #{e.message}"
        return 1
      end

      local_sha = Push.local_files(base).each_with_object({}) do |path, h|
        key = path.relative_path_from(base).to_s
        h[key] = Digest::SHA256.file(path).hexdigest
      end

      to_upload = local_sha.each_key.select { |key| remote_sha[key] != local_sha[key] }.sort
      to_download = remote_sha.each_key.select { |key| local_sha[key] != remote_sha[key] }.sort

      if to_upload.empty? && to_download.empty?
        out.puts "status: up to date, nothing to upload or download"
        return 0
      end

      unless to_upload.empty?
        out.puts "would upload (local -> server):"
        to_upload.each { |key| out.puts "  #{key}" }
      end

      unless to_download.empty?
        out.puts "would download (server -> local):"
        to_download.each { |key| out.puts "  #{key}" }
      end

      out.puts "status: #{to_upload.size} to upload, #{to_download.size} to download"
      0
    end
  end
end
