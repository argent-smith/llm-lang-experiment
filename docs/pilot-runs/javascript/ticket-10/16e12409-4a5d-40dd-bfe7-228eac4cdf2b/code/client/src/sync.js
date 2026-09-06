'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { toKey } = require('./blobKey');
const { fetchServerBlobs } = require('./serverApi');
const { hashFile, collectFiles, uploadBlob } = require('./push');
const { resolveLocalPath, downloadBlob } = require('./pull');

// State file sync uses to remember, between runs, which sha256 a key had
// the last time both sides agreed on it -- the "last known common state"
// needed to tell "only one side changed since last sync" (a plain
// push/pull) apart from a real conflict (both sides changed). It lives
// inside <dir> itself because run-client mounts exactly <dir> into the
// client container, and nothing outside that mount persists between
// separate `docker compose run` invocations.
const STATE_FILENAME = '.syncbox-sync-state.json';

async function readState(baseDir) {
  try {
    const raw = await fsp.readFile(path.join(baseDir, STATE_FILENAME), 'utf8');
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

async function writeState(baseDir, state) {
  await fsp.writeFile(path.join(baseDir, STATE_FILENAME), JSON.stringify(state, null, 2));
}

// Merges push and pull into one pass: a key present on only one side
// transfers to the other, exactly as push/pull would on their own. A key
// present on both sides with differing content is resolved against `state`
// (the sha256 recorded the last time this key was known to match): if only
// one side moved since then, that side's version is a plain transfer, not a
// conflict. If both moved -- or `state` has never seen this key, so there
// is no baseline to tell the two apart -- the spec's fixed conflict rule
// decides: the newer of local mtime / server modified_at wins, local wins
// on an exact tie. Never deletes: a key absent on one side just never gets
// a transfer proposed for that side, matching push/pull's own behavior.
async function sync({ dir, server }) {
  const baseDir = path.resolve(dir);
  const stat = await fsp.stat(baseDir).catch(() => null);
  if (!stat || !stat.isDirectory()) {
    throw new Error(`not a directory: ${dir}`);
  }

  const state = await readState(baseDir);

  const files = [];
  await collectFiles(baseDir, baseDir, files);

  const localShas = new Map();
  for (const filePath of files) {
    const key = toKey(filePath, baseDir);
    if (key === STATE_FILENAME) continue;
    localShas.set(key, await hashFile(filePath));
  }

  const serverBlobs = await fetchServerBlobs(server);
  serverBlobs.delete(STATE_FILENAME);

  const allKeys = Array.from(new Set([...localShas.keys(), ...serverBlobs.keys()])).sort();

  const uploaded = [];
  const downloaded = [];
  const unchanged = [];
  const failed = [];
  const nextState = { ...state };

  for (const key of allKeys) {
    const localSha = localShas.get(key);
    const serverMeta = serverBlobs.get(key);
    const serverSha = serverMeta ? serverMeta.sha256 : undefined;
    const localPath = resolveLocalPath(baseDir, key);

    try {
      if (localSha === serverSha) {
        unchanged.push(key);
        nextState[key] = localSha;
        continue;
      }

      if (serverSha === undefined) {
        // Only local has this key.
        const body = await fsp.readFile(localPath);
        await uploadBlob(server, key, body);
        uploaded.push(key);
        nextState[key] = localSha;
        continue;
      }

      if (localSha === undefined) {
        // Only the server has this key.
        const body = await downloadBlob(server, key);
        await fsp.mkdir(path.dirname(localPath), { recursive: true });
        await fsp.writeFile(localPath, body);
        downloaded.push(key);
        nextState[key] = serverSha;
        continue;
      }

      // Both sides have it, with different content: figure out whether
      // this is a one-sided change (plain transfer) or a real conflict.
      const baselineSha = state[key];
      const localChanged = baselineSha === undefined || localSha !== baselineSha;
      const serverChanged = baselineSha === undefined || serverSha !== baselineSha;

      let winner;
      if (serverChanged && !localChanged) {
        winner = 'server';
      } else if (localChanged && !serverChanged) {
        winner = 'local';
      } else {
        const localStat = await fsp.stat(localPath);
        const localMs = localStat.mtimeMs;
        const serverMs = Date.parse(serverMeta.modified_at);
        winner = localMs >= serverMs ? 'local' : 'server';
      }

      if (winner === 'local') {
        const body = await fsp.readFile(localPath);
        await uploadBlob(server, key, body);
        uploaded.push(key);
        nextState[key] = localSha;
      } else {
        const body = await downloadBlob(server, key);
        await fsp.mkdir(path.dirname(localPath), { recursive: true });
        await fsp.writeFile(localPath, body);
        downloaded.push(key);
        nextState[key] = serverSha;
      }
    } catch (err) {
      failed.push({ key, error: err.message });
    }
  }

  await writeState(baseDir, nextState);

  return { uploaded, downloaded, unchanged, failed };
}

module.exports = { sync, STATE_FILENAME };
