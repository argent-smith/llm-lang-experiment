// What sync remembers between runs: for each key, the SHA-256 that the local
// directory and the server last had in common. Kept outside the directory
// being synced, so that it never shows up as a file to push or compare.

import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const VERSION = 1;

/**
 * The directory holding sync state files: SYNCBOX_STATE_DIR if set, else
 * $XDG_STATE_HOME/syncbox, else ~/.local/state/syncbox.
 *
 * @param {Record<string, string | undefined>} env
 * @returns {string}
 */
export function stateDirectory(env) {
  if (env.SYNCBOX_STATE_DIR) {
    return env.SYNCBOX_STATE_DIR;
  }
  const base = env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
  return path.join(base, 'syncbox');
}

/**
 * The state file for one directory synced with one server: each pair has its
 * own, named after a hash of both.
 *
 * @param {string} stateDir
 * @param {string} server  base URL as the client uses it
 * @param {string} dir     the synced directory; resolved to its real path
 * @returns {Promise<string>}
 */
export async function stateFile(stateDir, server, dir) {
  const id = JSON.stringify([server, await fs.realpath(dir)]);
  return path.join(stateDir, `${createHash('sha256').update(id).digest('hex')}.json`);
}

/**
 * Reads the state saved by the previous sync.
 *
 * @param {string} file
 * @returns {Promise<Map<string, string>>} key -> SHA-256; empty if there is no
 *   state yet (or what is there is not a state file this version wrote)
 */
export async function loadState(file) {
  let text;
  try {
    text = await fs.readFile(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') {
      return new Map();
    }
    throw err;
  }
  let state;
  try {
    state = JSON.parse(text);
  } catch {
    return new Map();
  }
  if (state?.version !== VERSION || typeof state.files !== 'object' || state.files === null) {
    return new Map();
  }
  return new Map(Object.entries(state.files).filter(([, sha256]) => typeof sha256 === 'string'));
}

/**
 * Replaces the saved state, atomically: a crash leaves either the old state
 * or the new one, never a truncated file.
 *
 * @param {string} file
 * @param {Map<string, string>} files  key -> SHA-256
 */
export async function saveState(file, files) {
  const sorted = [...files].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const text = JSON.stringify({ version: VERSION, files: Object.fromEntries(sorted) }, null, 2);
  const temp = path.join(path.dirname(file), `.${path.basename(file)}.${randomBytes(8).toString('hex')}.tmp`);
  try {
    await fs.writeFile(temp, `${text}\n`, { flag: 'wx', flush: true });
    await fs.rename(temp, file);
  } catch (err) {
    await fs.rm(temp, { force: true });
    throw err;
  }
}
