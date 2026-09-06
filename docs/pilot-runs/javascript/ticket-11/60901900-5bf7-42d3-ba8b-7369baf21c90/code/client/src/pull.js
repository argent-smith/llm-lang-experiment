'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { encodeKeyForUrl } = require('./blobKey');
const { fetchServerBlobs, request } = require('./serverApi');
const { hashFile } = require('./push');

// Resolves a server-provided key to a path inside baseDir, refusing to
// write outside it. The server already rejects traversal keys at write
// time (ticket 5), so a well-behaved server never sends one back via
// GET /blobs — this is a defensive backstop, not the primary guard.
function resolveLocalPath(baseDir, key) {
  const dest = path.resolve(baseDir, ...key.split('/'));
  if (dest !== baseDir && !dest.startsWith(baseDir + path.sep)) {
    throw new Error(`key escapes target directory: ${key}`);
  }
  return dest;
}

async function localSha256(filePath) {
  try {
    return await hashFile(filePath);
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
}

async function downloadBlob(server, key, timeoutMs) {
  const res = await request(server, `/blobs/${encodeKeyForUrl(key)}`, {}, timeoutMs);
  if (!res.ok) {
    throw new Error(`GET /blobs/${key} failed: ${res.status} ${res.statusText}`);
  }
  try {
    return Buffer.from(await res.arrayBuffer());
  } catch (err) {
    throw new Error(`GET /blobs/${key} failed while reading response body: ${err.message}`);
  }
}

// Mirror image of push: fetches the server's blob list, diffs each entry's
// sha256 against the local file at that key (if any), and downloads
// whatever is missing or changed. Files already matching are left alone.
// Local files absent from the server's list are untouched — pull never
// deletes; that is sync/status territory (tickets 9-10), not this one.
async function pull({ dir, server, timeoutMs }) {
  const baseDir = path.resolve(dir);
  const stat = await fsp.stat(baseDir).catch(() => null);
  if (!stat || !stat.isDirectory()) {
    throw new Error(`not a directory: ${dir}`);
  }

  const serverBlobs = await fetchServerBlobs(server, timeoutMs);

  const downloaded = [];
  const skipped = [];
  const failed = [];

  for (const [key, meta] of serverBlobs) {
    try {
      const destPath = resolveLocalPath(baseDir, key);
      const existingSha256 = await localSha256(destPath);
      if (existingSha256 === meta.sha256) {
        skipped.push(key);
        continue;
      }

      const body = await downloadBlob(server, key, timeoutMs);
      await fsp.mkdir(path.dirname(destPath), { recursive: true });
      await fsp.writeFile(destPath, body);
      downloaded.push(key);
    } catch (err) {
      failed.push({ key, error: err.message });
    }
  }

  return { downloaded, skipped, failed };
}

module.exports = { pull, resolveLocalPath, downloadBlob };
