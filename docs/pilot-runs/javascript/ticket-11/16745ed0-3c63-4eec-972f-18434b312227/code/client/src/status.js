'use strict';

const fs = require('fs');
const fsp = fs.promises;
const crypto = require('crypto');
const { walkDir } = require('./walk');
const { listBlobs } = require('./http-client');

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

/**
 * Dry-run comparison of config.dir against the server's blob list by key and
 * sha256. Read-only: only ever calls GET /blobs and reads local files, never
 * writes to either side. Returns the keys push would upload (present
 * locally, missing or differing on the server) and the keys pull would
 * download (present on the server, missing or differing locally) - a file
 * that differs on both sides appears in both lists, since status reports
 * what each one-directional command would do independently, not a
 * conflict-resolved sync plan (that's a separate command).
 *
 * A local file that cannot be read (to compute its hash) is recorded in the
 * returned `failed` list rather than aborting the whole comparison - every
 * other file is still compared.
 */
async function run(config) {
  const stat = await fsp.stat(config.dir).catch(() => null);
  if (!stat || !stat.isDirectory()) {
    throw new Error(`not a directory: ${config.dir}`);
  }

  const files = await walkDir(config.dir);
  const remoteBlobs = await listBlobs(config.serverUrl);
  const remoteByKey = new Map(remoteBlobs.map((blob) => [blob.key, blob]));
  const localShaByKey = new Map();
  const failed = [];

  const toUpload = [];
  for (const file of files) {
    try {
      const sha256 = await sha256File(file.filePath);
      localShaByKey.set(file.key, sha256);
      const remote = remoteByKey.get(file.key);
      if (!remote || remote.sha256 !== sha256) {
        toUpload.push(file.key);
      }
    } catch (err) {
      failed.push({ key: file.key, error: err.message });
    }
  }

  const toDownload = [];
  for (const blob of remoteBlobs) {
    const localSha256 = localShaByKey.get(blob.key);
    if (localSha256 === undefined || localSha256 !== blob.sha256) {
      toDownload.push(blob.key);
    }
  }

  toUpload.sort();
  toDownload.sort();

  return { toUpload, toDownload, failed };
}

module.exports = { run };
