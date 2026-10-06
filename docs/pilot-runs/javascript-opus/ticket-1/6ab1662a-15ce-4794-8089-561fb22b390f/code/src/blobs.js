// Blob keys and on-disk blob storage.
//
// Layout inside the data directory:
//   blobs/<key>   blob contents, one regular file per key
//   tmp/          uploads in progress; renamed into blobs/ once complete,
//                 so readers never see a partially written blob

import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

// NAME_MAX on Linux filesystems, in bytes.
const MAX_SEGMENT_BYTES = 255;

// Filesystem errors that mean "this key cannot be stored as a file here"
// (name too long, a path component clashes with an existing file or
// directory) rather than a server fault.
const KEY_FS_ERRORS = new Set(['ENAMETOOLONG', 'ENOTDIR', 'EISDIR', 'EEXIST', 'EILSEQ']);

export class InvalidKeyError extends Error {
  constructor(message) {
    super(message);
    this.name = 'InvalidKeyError';
  }
}

/**
 * Decodes the percent-encoded key taken from the request path and checks
 * that it is a relative POSIX path that maps to exactly one file under the
 * storage root.
 *
 * @param {string} rawKey  key as it appears in the URL (still percent-encoded)
 * @returns {string} decoded key
 * @throws {InvalidKeyError}
 */
export function parseKey(rawKey) {
  let key;
  try {
    key = decodeURIComponent(rawKey);
  } catch {
    throw new InvalidKeyError('key is not valid percent-encoded UTF-8');
  }

  if (key === '') {
    throw new InvalidKeyError('key is empty');
  }
  if (!key.isWellFormed()) {
    throw new InvalidKeyError('key is not valid Unicode');
  }
  if (key.includes('\0')) {
    throw new InvalidKeyError('key contains a NUL character');
  }
  if (key.startsWith('/')) {
    throw new InvalidKeyError('key must be a relative path');
  }
  for (const segment of key.split('/')) {
    if (segment === '') {
      throw new InvalidKeyError('key contains an empty path segment');
    }
    if (segment === '.' || segment === '..') {
      throw new InvalidKeyError(`key contains a "${segment}" path segment`);
    }
    if (Buffer.byteLength(segment) > MAX_SEGMENT_BYTES) {
      throw new InvalidKeyError(`key path segment is longer than ${MAX_SEGMENT_BYTES} bytes`);
    }
  }
  return key;
}

export class BlobStore {
  /** @param {string} dataDir */
  constructor(dataDir) {
    this.root = path.join(dataDir, 'blobs');
    this.tmpDir = path.join(dataDir, 'tmp');
  }

  /**
   * Stores `source` under `key`, replacing any existing blob atomically.
   *
   * @param {string} key  a key accepted by parseKey()
   * @param {AsyncIterable<Buffer>} source
   * @returns {Promise<{ key: string, sha256: string, size: number }>}
   * @throws {InvalidKeyError} if the key cannot be stored as a file
   */
  async put(key, source) {
    await fs.mkdir(this.tmpDir, { recursive: true });
    const tmp = path.join(this.tmpDir, `${randomBytes(12).toString('hex')}.part`);

    const hash = createHash('sha256');
    let size = 0;
    try {
      const fh = await fs.open(tmp, 'wx');
      try {
        for await (const chunk of source) {
          hash.update(chunk);
          size += chunk.length;
          for (let offset = 0; offset < chunk.length; ) {
            offset += (await fh.write(chunk, offset)).bytesWritten;
          }
        }
        await fh.sync();
      } finally {
        await fh.close();
      }

      const target = path.join(this.root, ...key.split('/'));
      try {
        await fs.mkdir(path.dirname(target), { recursive: true });
        await fs.rename(tmp, target);
      } catch (err) {
        if (KEY_FS_ERRORS.has(err.code)) {
          throw new InvalidKeyError(`key cannot be stored as a file: ${err.code}`);
        }
        throw err;
      }
    } catch (err) {
      await fs.rm(tmp, { force: true });
      throw err;
    }

    return { key, sha256: hash.digest('hex'), size };
  }

  /**
   * Lists all blobs, sorted by key.
   *
   * @returns {Promise<Array<{ key: string, size: number, sha256: string, modified_at: string }>>}
   */
  async list() {
    const blobs = [];
    await this.#walk(this.root, [], blobs);
    return blobs.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  }

  async #walk(dir, prefix, out) {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch (err) {
      // Nothing stored yet, or the directory vanished while we walked.
      if (err.code === 'ENOENT') return;
      throw err;
    }
    for (const entry of entries) {
      const segments = [...prefix, entry.name];
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await this.#walk(full, segments, out);
      } else if (entry.isFile()) {
        const meta = await describe(full);
        if (meta) out.push({ key: segments.join('/'), ...meta });
      }
    }
  }
}

// Size, hash and mtime of one file, all taken from the same open handle so
// they stay consistent even if the blob is replaced concurrently. Returns
// null if the file disappeared in the meantime.
async function describe(file) {
  let fh;
  try {
    fh = await fs.open(file, 'r');
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
  try {
    const stat = await fh.stat();
    const hash = createHash('sha256');
    for await (const chunk of fh.createReadStream({ autoClose: false })) {
      hash.update(chunk);
    }
    return { size: stat.size, sha256: hash.digest('hex'), modified_at: stat.mtime.toISOString() };
  } finally {
    await fh.close();
  }
}
