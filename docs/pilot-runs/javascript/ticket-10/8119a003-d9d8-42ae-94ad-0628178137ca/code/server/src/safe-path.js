'use strict';

const path = require('path');

// A UTF-16 code unit in the surrogate range that isn't part of a valid pair.
// decodeURIComponent normally can't produce these from well-formed UTF-8
// percent-encoding, but we check anyway since such a string can't be
// represented safely as a filesystem path (Buffer.from silently mangles it
// into U+FFFD, which could make unrelated keys collide on disk).
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

/**
 * Validates a raw (still percent-encoded, single) path segment taken from
 * after "/blobs/" and turns it into a safe absolute filesystem path.
 *
 * Returns null if the segment is not a valid blob key: malformed
 * percent-encoding, an absolute path, a ".." component, an unrepresentable
 * filename (NUL byte, lone surrogate), or anything whose resolved path would
 * land outside dataDir.
 */
function resolveBlobPath(dataDir, rawSegment) {
  let key;
  try {
    key = decodeURIComponent(rawSegment);
  } catch {
    return null;
  }

  if (key.includes('\0') || LONE_SURROGATE.test(key)) {
    return null;
  }

  if (key.startsWith('/')) {
    return null;
  }

  if (key.split('/').includes('..')) {
    return null;
  }

  const root = path.resolve(dataDir);
  const filePath = path.resolve(root, key);

  if (!filePath.startsWith(root + path.sep)) {
    return null;
  }

  return { key, filePath };
}

module.exports = { resolveBlobPath };
