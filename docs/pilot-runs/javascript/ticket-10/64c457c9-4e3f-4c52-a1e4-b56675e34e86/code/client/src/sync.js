'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { walkDir } = require('./walk');
const { listBlobs, putBlob, getBlob } = require('./http-client');

// Client-local bookkeeping file recording the "last known common state"
// (key -> sha256) as of the end of the previous successful sync run - the
// three-way-merge base used to tell "only one side changed since last time"
// apart from a genuine two-sided conflict. Lives inside <dir> so it travels
// with the directory, but is never itself treated as syncable content.
const MANIFEST_FILENAME = '.syncbox-sync-state.json';

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function readManifest(manifestPath) {
  try {
    const raw = await fsp.readFile(manifestPath, 'utf8');
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    // Missing, unreadable, or corrupt manifest: treat as "no known common
    // state yet", i.e. a first sync - every difference falls back to the
    // mtime tie-break below rather than the three-way-merge shortcuts.
    return {};
  }
}

async function uploadFile(config, key, local) {
  const stat = await fsp.stat(local.filePath);
  await putBlob(config.serverUrl, key, fs.createReadStream(local.filePath), { contentLength: stat.size });
}

async function downloadFile(config, key) {
  const filePath = path.join(config.dir, ...key.split('/'));
  const body = await getBlob(config.serverUrl, key);
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.writeFile(filePath, body);
}

/**
 * Bidirectionally reconciles config.dir with the server by key and sha256,
 * folding push and pull into one pass: a file present on only one side is
 * transferred to the other (local-only -> upload, server-only -> download).
 * A file present on both sides with differing sha256 is a candidate
 * conflict, resolved against MANIFEST_FILENAME's record of what was common
 * as of the last successful sync (absent on a first run):
 *   - if the manifest shows one side still matches the last-known-common
 *     sha256, only the other side actually changed, and that side wins
 *     outright (no mtime comparison needed);
 *   - otherwise both sides changed (or there is no manifest entry at all,
 *     e.g. the first sync) - the strict SYNCBOX-SPEC.md rule applies: newer
 *     modified_at/mtime wins, local wins ties.
 * Never deletes a file on either side - a key present remotely but absent
 * locally (even if it was synced before and only removed on one side) is
 * simply re-downloaded, the same as any other server-only key.
 */
async function run(config) {
  await fsp.mkdir(config.dir, { recursive: true });
  const manifestPath = path.join(config.dir, MANIFEST_FILENAME);

  const [manifest, localFiles, remoteBlobs] = await Promise.all([
    readManifest(manifestPath),
    walkDir(config.dir),
    listBlobs(config.serverUrl),
  ]);

  const localByKey = new Map();
  for (const file of localFiles) {
    if (file.key === MANIFEST_FILENAME) continue;
    const [sha256, stat] = await Promise.all([sha256File(file.filePath), fsp.stat(file.filePath)]);
    localByKey.set(file.key, { filePath: file.filePath, sha256, mtimeMs: stat.mtimeMs });
  }

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
      await uploadFile(config, key, local);
      uploaded.push(key);
      newManifest[key] = local.sha256;
      continue;
    }

    if (!local && remote) {
      await downloadFile(config, key);
      downloaded.push(key);
      newManifest[key] = remote.sha256;
      continue;
    }

    if (local.sha256 === remote.sha256) {
      unchanged.push(key);
      newManifest[key] = local.sha256;
      continue;
    }

    const baseSha256 = manifest[key];
    let winner;
    if (baseSha256 !== undefined && baseSha256 === local.sha256) {
      winner = 'remote'; // local untouched since last sync, so only remote changed
    } else if (baseSha256 !== undefined && baseSha256 === remote.sha256) {
      winner = 'local'; // remote untouched since last sync, so only local changed
    } else {
      const remoteMs = Date.parse(remote.modified_at);
      winner = local.mtimeMs >= remoteMs ? 'local' : 'remote';
    }

    if (winner === 'local') {
      await uploadFile(config, key, local);
      uploaded.push(key);
      newManifest[key] = local.sha256;
    } else {
      await downloadFile(config, key);
      downloaded.push(key);
      newManifest[key] = remote.sha256;
    }
  }

  await fsp.writeFile(manifestPath, JSON.stringify(newManifest, null, 2));

  return { uploaded, downloaded, unchanged };
}

module.exports = { run, MANIFEST_FILENAME };
