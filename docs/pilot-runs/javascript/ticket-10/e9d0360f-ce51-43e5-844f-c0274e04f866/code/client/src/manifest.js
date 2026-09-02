'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { RESERVED_DIR } = require('./walk');

const MANIFEST_FILE = 'manifest.json';

function manifestPath(dir) {
  return path.join(dir, RESERVED_DIR, MANIFEST_FILE);
}

/**
 * Reads sync's record of the last-known-common state between <dir> and the
 * server: key -> sha256 that both sides agreed on as of the previous
 * successful sync. Missing or unreadable manifest (e.g. first-ever sync)
 * yields an empty baseline, not an error.
 */
async function readManifest(dir) {
  const raw = await fsp.readFile(manifestPath(dir), 'utf8').catch(() => null);
  if (raw === null) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

async function writeManifest(dir, manifest) {
  const file = manifestPath(dir);
  await fsp.mkdir(path.dirname(file), { recursive: true });
  await fsp.writeFile(file, JSON.stringify(manifest, null, 2));
}

module.exports = { readManifest, writeManifest };
