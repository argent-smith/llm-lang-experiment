'use strict';

const fs = require('fs');
const fsp = fs.promises;
const crypto = require('crypto');
const { walkDir } = require('./walk');
const { listBlobs, putBlob } = require('./http-client');

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
 * Uploads every file under config.dir that is missing from the server or
 * whose content (by sha256) differs from the server's copy. Files whose
 * hash already matches the server are left untouched.
 */
async function run(config) {
  const stat = await fsp.stat(config.dir).catch(() => null);
  if (!stat || !stat.isDirectory()) {
    throw new Error(`not a directory: ${config.dir}`);
  }

  const files = await walkDir(config.dir);
  const remoteBlobs = await listBlobs(config.serverUrl);
  const remoteByKey = new Map(remoteBlobs.map((blob) => [blob.key, blob]));

  const uploaded = [];
  const skipped = [];

  for (const file of files) {
    const sha256 = await sha256File(file.filePath);
    const remote = remoteByKey.get(file.key);

    if (remote && remote.sha256 === sha256) {
      skipped.push(file.key);
      continue;
    }

    const fileStat = await fsp.stat(file.filePath);
    await putBlob(config.serverUrl, file.key, fs.createReadStream(file.filePath), {
      contentLength: fileStat.size,
    });
    uploaded.push(file.key);
  }

  return { uploaded, skipped };
}

module.exports = { run };
