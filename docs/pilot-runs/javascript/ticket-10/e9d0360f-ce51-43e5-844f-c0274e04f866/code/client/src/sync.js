'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { walkDir } = require('./walk');
const { listBlobs, putBlob, getBlob } = require('./http-client');
const { readManifest, writeManifest } = require('./manifest');

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function uploadFile(serverUrl, key, filePath) {
  const fileStat = await fsp.stat(filePath);
  await putBlob(serverUrl, key, fs.createReadStream(filePath), { contentLength: fileStat.size });
}

async function downloadBlob(serverUrl, dir, key) {
  const filePath = path.join(dir, ...key.split('/'));
  const body = await getBlob(serverUrl, key);
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.writeFile(filePath, body);
}

/**
 * Two-way sync of <dir> against the server by key and sha256. A key present
 * on only one side is transferred to the other (push-like / pull-like). A
 * key present on both sides with differing sha256 is a change on at least
 * one side relative to the last known common state recorded in the local
 * manifest (see manifest.js): if only one side moved away from that
 * baseline, its version wins unconditionally; if both did (or there is no
 * baseline yet, e.g. the first-ever sync of that key), it's a genuine
 * conflict resolved by the fixed rule from SYNCBOX-SPEC.md - newer
 * modified_at/mtime wins, local wins on a tie. Never deletes on either side.
 */
async function run(config) {
  await fsp.mkdir(config.dir, { recursive: true });

  const [files, remoteBlobs, manifest] = await Promise.all([
    walkDir(config.dir),
    listBlobs(config.serverUrl),
    readManifest(config.dir),
  ]);

  const localByKey = new Map(files.map((file) => [file.key, file]));
  const remoteByKey = new Map(remoteBlobs.map((blob) => [blob.key, blob]));
  const allKeys = new Set([...localByKey.keys(), ...remoteByKey.keys()]);

  const uploaded = [];
  const downloaded = [];
  const unchanged = [];
  const newManifest = {};

  for (const key of [...allKeys].sort()) {
    const local = localByKey.get(key);
    const remote = remoteByKey.get(key);

    if (local && !remote) {
      await uploadFile(config.serverUrl, key, local.filePath);
      newManifest[key] = { sha256: await sha256File(local.filePath) };
      uploaded.push(key);
      continue;
    }

    if (!local && remote) {
      await downloadBlob(config.serverUrl, config.dir, key);
      newManifest[key] = { sha256: remote.sha256 };
      downloaded.push(key);
      continue;
    }

    const localSha256 = await sha256File(local.filePath);
    if (localSha256 === remote.sha256) {
      newManifest[key] = { sha256: localSha256 };
      unchanged.push(key);
      continue;
    }

    const baseline = manifest[key];
    const localChanged = !baseline || baseline.sha256 !== localSha256;
    const remoteChanged = !baseline || baseline.sha256 !== remote.sha256;

    let direction;
    if (localChanged && !remoteChanged) {
      direction = 'upload';
    } else if (remoteChanged && !localChanged) {
      direction = 'download';
    } else {
      const localMtimeMs = (await fsp.stat(local.filePath)).mtimeMs;
      const remoteModifiedMs = Date.parse(remote.modified_at);
      direction = localMtimeMs >= remoteModifiedMs ? 'upload' : 'download';
    }

    if (direction === 'upload') {
      await uploadFile(config.serverUrl, key, local.filePath);
      newManifest[key] = { sha256: localSha256 };
      uploaded.push(key);
    } else {
      await downloadBlob(config.serverUrl, config.dir, key);
      newManifest[key] = { sha256: remote.sha256 };
      downloaded.push(key);
    }
  }

  await writeManifest(config.dir, newManifest);

  return { uploaded, downloaded, unchanged };
}

module.exports = { run };
