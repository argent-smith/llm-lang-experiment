import fs from 'node:fs/promises';

import { Failures } from './failures.js';
import { keySegments, listFiles, sha256File } from './local-files.js';
import { download, inspectTarget } from './pull.js';
import { loadState, saveState, stateFile } from './sync-state.js';

/**
 * Decides, for every key on either side, which way it goes.
 *
 * A file on one side only is copied to the other. A file whose SHA-256
 * differs between the sides goes from the side that changed since the last
 * sync (`base`) to the side that did not. If both changed (or there is no
 * base for it yet), the more recent modification time wins: the local mtime
 * against the server's modified_at; when they are equal, the local copy
 * wins. Nothing is ever deleted.
 *
 * @param {{
 *   local: Map<string, { sha256: string, mtime: number }>,  mtime in whole ms, as modified_at
 *   remote: Map<string, { sha256: string, modified_at: string }>,
 *   base: Map<string, string>,  key -> SHA-256 both sides had at the last sync
 * }} sides
 * @returns {Array<{
 *   key: string,
 *   action: 'upload' | 'download' | 'none',
 *   conflict?: 'local-newer' | 'server-newer' | 'same-time',
 * }>} sorted by key
 */
export function planSync({ local, remote, base }) {
  const keys = [...new Set([...local.keys(), ...remote.keys()])].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return keys.map((key) => {
    const mine = local.get(key);
    const theirs = remote.get(key);
    if (theirs === undefined) {
      return { key, action: 'upload' };
    }
    if (mine === undefined) {
      return { key, action: 'download' };
    }
    if (mine.sha256 === theirs.sha256) {
      return { key, action: 'none' };
    }
    const known = base.get(key);
    const localChanged = mine.sha256 !== known;
    const remoteChanged = theirs.sha256 !== known;
    if (!remoteChanged) {
      return { key, action: 'upload' };
    }
    if (!localChanged) {
      return { key, action: 'download' };
    }
    const localTime = mine.mtime;
    const remoteTime = Date.parse(theirs.modified_at);
    if (remoteTime > localTime) {
      return { key, action: 'download', conflict: 'server-newer' };
    }
    return { key, action: 'upload', conflict: localTime === remoteTime ? 'same-time' : 'local-newer' };
  });
}

const CONFLICT_NOTES = {
  'local-newer': 'changed on both sides, local copy is newer',
  'server-newer': 'changed on both sides, server copy is newer',
  'same-time': 'changed on both sides at the same time, local copy kept',
};

/**
 * Two-way sync between `dir` and the server: uploads what only `dir` has or
 * changed, downloads what only the server has or changed, and settles files
 * changed on both sides by planSync()'s rule. Nothing is deleted on either
 * side.
 *
 * Uploads and downloads work as in push and pull (downloads go through a
 * temporary file, verified, and skip keys that are not plain relative paths
 * or lead through symbolic links). What both sides have in common afterwards
 * is saved in a state file under `stateDir`, the base for the next sync; it
 * is saved even when the sync fails or is interrupted, for what got done.
 *
 * A file that fails is recorded in `failed` and the rest are still synced;
 * see Failures for when the rest are given up on (`stopped`). A local file
 * or directory that cannot be read is left alone in both directions, along
 * with every blob under such a directory: without knowing what is there, a
 * download could overwrite local changes.
 *
 * @param {{
 *   dir: string,
 *   client: import('./client.js').SyncboxClient,
 *   stateDir: string,                   where sync state is kept, see sync-state.js
 *   log?: (line: string) => void,       progress, one line per transferred file
 *   warn?: (line: string) => void,      files and blobs left out
 *   signal?: AbortSignal,               stops the sync, rejecting with an AbortError
 * }} options
 * @returns {Promise<{
 *   uploaded: string[],
 *   downloaded: string[],
 *   upToDate: string[],
 *   conflicts: string[],
 *   failed: Array<{ key: string, reason: string, error: Error }>,
 *   stopped?: { error: import('./client.js').UnreachableError, remaining: number },
 * }>} keys
 * @throws {import('./client.js').RequestError} if the server's list cannot be had
 */
export async function sync({ dir, client, stateDir, log = () => {}, warn = () => {}, signal }) {
  const failures = new Failures();
  const unreadableDirs = [];
  const files = await listFiles(dir, {
    onSkip: (relPath, reason) => warn(`skipping ${relPath}: ${reason}`),
    onError: (relPath, err) => {
      unreadableDirs.push(relPath);
      failures.add(`${relPath}/`, err);
    },
  });
  const local = new Map();
  const unreadable = new Set();
  await failures.each(files, undefined, async ({ key, path }) => {
    signal?.throwIfAborted();
    try {
      const stat = await fs.stat(path);
      // In whole milliseconds the way the server gets modified_at from its own
      // stat() (rounded, not truncated), so equal file times compare as equal.
      local.set(key, { path, mtime: stat.mtime.getTime(), sha256: await sha256File(path) });
    } catch (err) {
      unreadable.add(key);
      throw err;
    }
  });
  const remote = new Map((await client.list({ signal })).map((blob) => [blob.key, blob]));
  // What could not be read locally is not synced either way.
  const unknown = (key) => unreadable.has(key) || unreadableDirs.some((d) => key.startsWith(`${d}/`));
  const comparable = new Map([...remote].filter(([key]) => !unknown(key)));

  await fs.mkdir(stateDir, { recursive: true });
  const file = await stateFile(stateDir, client.base, dir);
  const base = await loadState(file);

  // Starts as the old base: keys not synced (failed, left out or not
  // reached) keep what was last known about them.
  const common = new Map(base);
  const result = { uploaded: [], downloaded: [], upToDate: [], conflicts: [] };
  let done = false;
  try {
    await failures.each(planSync({ local, remote: comparable, base }), (item) => item.action, async ({ key, action, conflict }) => {
      signal?.throwIfAborted();
      const note = conflict === undefined ? '' : ` (${CONFLICT_NOTES[conflict]})`;
      if (action === 'none') {
        common.set(key, local.get(key).sha256);
        result.upToDate.push(key);
        return;
      }
      if (action === 'upload') {
        const { sha256 } = local.get(key);
        const stored = await client.put(key, local.get(key).path, { signal });
        // What the server got, in case the file changed after it was hashed.
        common.set(key, typeof stored?.sha256 === 'string' ? stored.sha256 : sha256);
        result.uploaded.push(key);
        log(`uploaded ${key}${note}`);
      } else {
        const blob = remote.get(key);
        const segments = keySegments(key);
        if (segments === null) {
          warn(`skipping ${JSON.stringify(key)}: key is not a relative path inside the directory`);
          return;
        }
        const target = await inspectTarget(dir, key, segments);
        if (target.skip !== undefined) {
          warn(`skipping ${key}: ${target.skip}`);
          return;
        }
        await download(client, blob, target, signal);
        common.set(key, blob.sha256);
        result.downloaded.push(key);
        log(`downloaded ${key}${note}`);
      }
      if (conflict !== undefined) {
        result.conflicts.push(key);
      }
    });
    // Gone from both sides: nothing in common to remember.
    for (const key of common.keys()) {
      if (!local.has(key) && !unknown(key) && !remote.has(key)) {
        common.delete(key);
      }
    }
    done = true;
  } finally {
    try {
      await saveState(file, common);
    } catch (err) {
      // Not worth hiding the error that stopped the sync.
      if (done) {
        throw Object.assign(new Error(`cannot save sync state to ${file}: ${err.message}`, { cause: err }), { code: err.code });
      }
    }
  }
  return { ...result, ...failures.result() };
}
