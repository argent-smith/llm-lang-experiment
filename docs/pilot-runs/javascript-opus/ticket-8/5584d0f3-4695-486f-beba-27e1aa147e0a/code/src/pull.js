import { randomBytes } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';

import { RequestError } from './client.js';
import { keySegments, sha256File } from './local-files.js';

/** A blob that cannot be written because of what is already in the directory. */
export class LocalConflictError extends Error {
  constructor(message) {
    super(message);
    this.name = 'LocalConflictError';
  }
}

/**
 * Downloads every blob that `dir` lacks or holds with different contents,
 * writing it to the relative path named by its key and creating missing
 * subdirectories (and `dir` itself). Files whose SHA-256 matches the
 * server's copy are not fetched again. Nothing is deleted on either side.
 * Stops at the first failure.
 *
 * Each file is written to a temporary file next to it and renamed into
 * place once complete and verified against the SHA-256 the server listed,
 * so an interrupted pull never leaves a truncated file behind.
 *
 * Nothing is written outside `dir`: keys that are not plain relative paths
 * are skipped, and so are paths that would lead through or onto a symbolic
 * link (push does not follow those either).
 *
 * @param {{
 *   dir: string,
 *   client: import('./client.js').SyncboxClient,
 *   log?: (line: string) => void,   progress, one line per downloaded file
 *   warn?: (line: string) => void,  blobs left out
 *   signal?: AbortSignal,           stops the pull, rejecting with an AbortError
 * }} options
 * @returns {Promise<{ downloaded: string[], upToDate: string[] }>} keys
 * @throws {LocalConflictError} if a blob's path is taken locally by
 *   something other than a regular file (e.g. a directory)
 */
export async function pull({ dir, client, log = () => {}, warn = () => {}, signal }) {
  await checkDirectory(dir);
  const blobs = (await client.list({ signal })).sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  await fs.mkdir(dir, { recursive: true });

  const downloaded = [];
  const upToDate = [];
  for (const blob of blobs) {
    signal?.throwIfAborted();
    const segments = keySegments(blob.key);
    if (segments === null) {
      warn(`skipping ${JSON.stringify(blob.key)}: key is not a relative path inside the directory`);
      continue;
    }
    const target = await inspectTarget(dir, blob.key, segments);
    if (target.skip !== undefined) {
      warn(`skipping ${blob.key}: ${target.skip}`);
      continue;
    }
    if (target.mode !== undefined && (await sha256File(target.path)) === blob.sha256) {
      upToDate.push(blob.key);
      continue;
    }
    await download(client, blob, target, signal);
    downloaded.push(blob.key);
    log(`downloaded ${blob.key}`);
  }
  return { downloaded, upToDate };
}

/** `dir` may be missing (pull creates it), but if it exists it must be a directory. */
async function checkDirectory(dir) {
  let stat;
  try {
    stat = await fs.stat(dir);
  } catch (err) {
    if (err.code === 'ENOENT') {
      return;
    }
    throw err;
  }
  if (!stat.isDirectory()) {
    const err = new Error(`not a directory: ${dir}`);
    err.code = 'ENOTDIR';
    throw err;
  }
}

/**
 * Looks at what is at a key's path in `dir` now, without following symbolic
 * links anywhere below `dir`.
 *
 * @returns {Promise<{ path: string, mode?: number, skip?: string }>}
 *   `mode` is set if a regular file is there; `skip` says why the blob
 *   must be left alone
 */
async function inspectTarget(dir, key, segments) {
  let current = dir;
  for (let i = 0; i < segments.length; i++) {
    current = path.join(current, segments[i]);
    const isLast = i === segments.length - 1;
    const where = segments.slice(0, i + 1).join('/');
    let stat;
    try {
      stat = await fs.lstat(current);
    } catch (err) {
      if (err.code === 'ENOENT') {
        break;
      }
      throw err;
    }
    if (stat.isSymbolicLink()) {
      return { skip: isLast ? 'symbolic link' : `${where} is a symbolic link` };
    }
    if (isLast) {
      if (stat.isDirectory()) {
        throw new LocalConflictError(`cannot write ${key}: a directory is in the way`);
      }
      if (!stat.isFile()) {
        return { skip: 'not a regular file' };
      }
      return { path: current, mode: stat.mode & 0o7777 };
    }
    if (!stat.isDirectory()) {
      throw new LocalConflictError(`cannot write ${key}: ${where} is not a directory`);
    }
  }
  return { path: path.join(dir, ...segments) };
}

async function download(client, blob, target, signal) {
  const parent = path.dirname(target.path);
  await fs.mkdir(parent, { recursive: true });
  const temp = path.join(parent, `.syncbox-${randomBytes(8).toString('hex')}.part`);
  // flush: fsync before closing, so that the renamed file has its contents
  // on disk even if the machine goes down right after.
  const output = createWriteStream(temp, { flags: 'wx', flush: true });
  try {
    const received = await client.download(blob.key, output, { signal });
    if (received.sha256 !== blob.sha256) {
      throw new RequestError(
        `GET ${blob.key}: the downloaded contents do not match the SHA-256 listed by the server ` +
          '(was the blob changed during the pull?)',
      );
    }
    if (target.mode !== undefined) {
      // Replacing a file keeps its permissions.
      await fs.chmod(temp, target.mode);
    }
    await fs.rename(temp, target.path);
  } catch (err) {
    // Still open if the server refused before sending any content. Waiting
    // for the close also waits for the open, which creates the file.
    if (!output.closed) {
      await new Promise((resolve) => output.once('close', resolve).destroy());
    }
    await fs.rm(temp, { force: true });
    throw err;
  }
}
