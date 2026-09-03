require "find"
require "pathname"

module Syncbox
  # Enumerates the regular files under a directory, keyed by their POSIX
  # path relative to that directory -- the same convention GET /blobs uses
  # for `key`. Shared by push/pull/status/sync so all four agree on what
  # counts as a syncable file.
  module LocalFiles
    # Reserved filename for Sync's local manifest (Syncbox::Manifest).
    # Excluded here so no command ever treats it as an ordinary file to
    # transfer -- mirrors the server's own exclusion of its reserved
    # scratch directory (TMP_DIR_NAME) from listings.
    MANIFEST_FILENAME = ".syncbox-manifest.json"

    def self.list(dir)
      root = Pathname.new(File.expand_path(dir))
      files = {}

      Find.find(root.to_s) do |path|
        next unless File.file?(path)

        key = Pathname.new(path).relative_path_from(root).to_s
        next if key == MANIFEST_FILENAME

        files[key] = path
      end

      files
    end
  end
end
