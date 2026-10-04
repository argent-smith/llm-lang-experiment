// The client's view of a local directory: which files it holds, under which
// keys, with which contents.

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';

// ignoreBOM keeps a leading U+FEFF, which is part of the name.
const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

/**
 * Lists the regular files under `root`, recursively, with their keys: the
 * path relative to `root` with "/" as the separator, the same convention the
 * server uses. Symbolic links and special files are not followed or read;
 * neither are names that are not valid UTF-8, which no key can express.
 * Each of those is reported through `onSkip` instead.
 *
 * @param {string} root
 * @param {{ onSkip?: (relPath: string, reason: string) => void }} [options]
 * @returns {Promise<Array<{ key: string, path: string }>>} sorted by key
 * @throws {Error} if `root` is not a readable directory
 */
export async function listFiles(root, { onSkip = () => {} } = {}) {
  const stat = await fsp.stat(root);
  if (!stat.isDirectory()) {
    const err = new Error(`not a directory: ${root}`);
    err.code = 'ENOTDIR';
    throw err;
  }
  const files = [];
  await walk(root, [], files, onSkip);
  return files.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
}

async function walk(dir, prefix, out, onSkip) {
  // Names as raw bytes, so that one which is not valid UTF-8 is noticed
  // instead of silently becoming U+FFFD.
  const entries = await fsp.readdir(dir, { withFileTypes: true, encoding: 'buffer' });
  for (const entry of entries) {
    let name;
    try {
      name = utf8.decode(entry.name);
    } catch {
      onSkip([...prefix, entry.name.toString()].join('/'), 'file name is not valid UTF-8');
      continue;
    }
    const segments = [...prefix, name];
    const full = path.join(dir, name);
    if (entry.isDirectory()) {
      await walk(full, segments, out, onSkip);
    } else if (entry.isFile()) {
      out.push({ key: segments.join('/'), path: full });
    } else if (entry.isSymbolicLink()) {
      onSkip(segments.join('/'), 'symbolic link');
    } else {
      onSkip(segments.join('/'), 'not a regular file');
    }
  }
}

/**
 * @param {string} file
 * @returns {Promise<string>} SHA-256 of the file's contents, in hex
 */
export async function sha256File(file) {
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) {
    hash.update(chunk);
  }
  return hash.digest('hex');
}
