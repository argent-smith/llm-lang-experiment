'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { toKey } = require('./blobKey');
const { fetchServerBlobs } = require('./serverApi');
const { hashFile, collectFiles } = require('./push');

// Dry-run diff between <dir> and the server's blob list: for every key that
// exists on either side, decides whether push (upload) and/or pull
// (download) would apply -- a key that differs on both sides satisfies both
// conditions independently and lands in both lists, since resolving that
// down to a single winning direction is sync's conflict rule (ticket 10),
// not this one. Never touches local files or makes any PUT/DELETE call; the
// only network request is the initial GET /blobs, whose sha256 field is
// enough for a full comparison without downloading a single blob body.
async function status({ dir, server, timeoutMs }) {
  const baseDir = path.resolve(dir);
  const stat = await fsp.stat(baseDir).catch(() => null);
  if (!stat || !stat.isDirectory()) {
    throw new Error(`not a directory: ${dir}`);
  }

  const files = [];
  await collectFiles(baseDir, baseDir, files);

  const localShas = new Map();
  const failed = [];
  for (const filePath of files) {
    const key = toKey(filePath, baseDir);
    try {
      localShas.set(key, await hashFile(filePath));
    } catch (err) {
      failed.push({ key, error: err.message });
    }
  }

  const serverBlobs = await fetchServerBlobs(server, timeoutMs);

  const failedKeys = new Set(failed.map((f) => f.key));
  const allKeys = Array.from(new Set([...localShas.keys(), ...serverBlobs.keys()]))
    .filter((key) => !failedKeys.has(key))
    .sort();

  const toUpload = [];
  const toDownload = [];
  const unchanged = [];

  for (const key of allKeys) {
    const localSha = localShas.get(key);
    const serverMeta = serverBlobs.get(key);
    const serverSha = serverMeta ? serverMeta.sha256 : undefined;

    const wouldUpload = localSha !== undefined && localSha !== serverSha;
    const wouldDownload = serverSha !== undefined && serverSha !== localSha;

    if (wouldUpload) toUpload.push(key);
    if (wouldDownload) toDownload.push(key);
    if (!wouldUpload && !wouldDownload) unchanged.push(key);
  }

  return { toUpload, toDownload, unchanged, failed };
}

module.exports = { status };
