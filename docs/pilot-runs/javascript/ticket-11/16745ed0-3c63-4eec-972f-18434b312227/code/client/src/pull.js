'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { listBlobs, getBlob } = require('./http-client');

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function localSha256(filePath) {
  const stat = await fsp.stat(filePath).catch(() => null);
  if (!stat || !stat.isFile()) return null;
  return sha256File(filePath);
}

/**
 * Downloads every blob the server has that is missing under config.dir or
 * whose content (by sha256) differs from the local copy, writing each one
 * to the relative POSIX path given by its key (creating subdirectories as
 * needed). Files whose hash already matches the server are left untouched.
 *
 * A failure on one blob (network error, non-2xx from the server, local
 * write failure) is recorded in the returned `failed` list rather than
 * aborting the whole run - every other blob is still attempted.
 */
async function run(config) {
  await fsp.mkdir(config.dir, { recursive: true });

  const remoteBlobs = await listBlobs(config.serverUrl);

  const downloaded = [];
  const skipped = [];
  const failed = [];

  for (const blob of remoteBlobs) {
    try {
      const filePath = path.join(config.dir, ...blob.key.split('/'));
      const existingSha256 = await localSha256(filePath);

      if (existingSha256 === blob.sha256) {
        skipped.push(blob.key);
        continue;
      }

      const body = await getBlob(config.serverUrl, blob.key);
      await fsp.mkdir(path.dirname(filePath), { recursive: true });
      await fsp.writeFile(filePath, body);
      downloaded.push(blob.key);
    } catch (err) {
      failed.push({ key: blob.key, error: err.message });
    }
  }

  return { downloaded, skipped, failed };
}

module.exports = { run };
