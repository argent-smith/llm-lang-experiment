'use strict';

const path = require('path');

// Converts an absolute file path into the POSIX-relative blob key
// convention shared with the server (relative to baseDir, "/"-separated
// regardless of host path separator).
function toKey(fullPath, baseDir) {
  return path.relative(baseDir, fullPath).split(path.sep).join('/');
}

// Percent-encodes each path segment independently so a literal "/" in the
// key is preserved as a path separator, matching the server's per-segment
// decodeURIComponent in parseBlobKey.
function encodeKeyForUrl(key) {
  return key.split('/').map(encodeURIComponent).join('/');
}

module.exports = { toKey, encodeKeyForUrl };
