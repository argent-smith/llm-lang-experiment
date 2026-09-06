'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { toKey, encodeKeyForUrl } = require('./blobKey');

function hashFile(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

async function collectFiles(dir, baseDir, out) {
  const entries = await fsp.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await collectFiles(full, baseDir, out);
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
}

async function fetchServerBlobs(server) {
  let res;
  try {
    res = await fetch(`${server}/blobs`);
  } catch (err) {
    throw new Error(`cannot reach server at ${server}: ${err.message}`);
  }
  if (!res.ok) {
    throw new Error(`GET /blobs failed: ${res.status} ${res.statusText}`);
  }
  const items = await res.json();
  const map = new Map();
  for (const item of items) map.set(item.key, item);
  return map;
}

// Recursively walks `dir`, diffs each file's sha256 against the server's
// blob list, and PUTs whatever is missing or changed. Files whose content
// already matches the server are left alone. Per-file failures are
// collected rather than aborting the whole push; a server that can't be
// reached at all (the initial GET /blobs) aborts immediately, since there
// is nothing meaningful to diff against.
async function push({ dir, server }) {
  const baseDir = path.resolve(dir);
  const stat = await fsp.stat(baseDir).catch(() => null);
  if (!stat || !stat.isDirectory()) {
    throw new Error(`not a directory: ${dir}`);
  }

  const files = [];
  await collectFiles(baseDir, baseDir, files);

  const serverBlobs = await fetchServerBlobs(server);

  const uploaded = [];
  const skipped = [];
  const failed = [];

  for (const filePath of files) {
    const key = toKey(filePath, baseDir);
    try {
      const sha256 = await hashFile(filePath);
      const existing = serverBlobs.get(key);
      if (existing && existing.sha256 === sha256) {
        skipped.push(key);
        continue;
      }

      const body = await fsp.readFile(filePath);
      const res = await fetch(`${server}/blobs/${encodeKeyForUrl(key)}`, {
        method: 'PUT',
        body,
      });
      if (!res.ok) {
        throw new Error(`PUT /blobs/${key} failed: ${res.status} ${res.statusText}`);
      }
      uploaded.push(key);
    } catch (err) {
      failed.push({ key, error: err.message });
    }
  }

  return { uploaded, skipped, failed };
}

module.exports = { push, collectFiles, hashFile };
