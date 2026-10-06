// Blob keys and on-disk blob storage.
//
// Layout inside the data directory:
//   blobs/<key>   blob contents, one regular file per key
//   tmp/          uploads in progress; renamed into blobs/ once complete,
//                 so readers never see a partially written blob
//
// Directory traversal is stopped in two layers: parseKey() rejects keys
// that are not plain relative paths, and BlobStore checks that every path
// it touches resolves strictly inside the blob root, both lexically and
// after following symlinks found on disk (the server never creates
// symlinks itself, but one may be planted in the data directory by hand).

import { createHash, randomBytes } from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
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
    this.root = path.resolve(dataDir, 'blobs');
    this.tmpDir = path.resolve(dataDir, 'tmp');
  }

  /**
   * Maps a key to its absolute path on disk. parseKey() already rejects
   * every key this refuses; this is the backstop that does not rely on it.
   *
   * @param {string} key
   * @returns {string}
   * @throws {InvalidKeyError} if the resolved path is not strictly inside the root
   */
  pathOf(key) {
    if (typeof key !== 'string' || key === '' || key.includes('\0')) {
      throw new InvalidKeyError('key cannot be stored as a file');
    }
    const segments = key.split('/');
    const target = path.resolve(this.root, ...segments);
    // Resolving must change nothing: a "..", ".", empty or absolute segment
    // would make the result differ from plain concatenation.
    if (!target.startsWith(this.root + path.sep) || target !== this.root + path.sep + segments.join(path.sep)) {
      throw new InvalidKeyError('key resolves outside the storage root');
    }
    return target;
  }

  /**
   * Checks that `dir`, with symlinks followed, is the blob root or inside
   * it. A directory that does not exist yet is judged by its nearest
   * existing ancestor, which is where mkdir would start creating.
   *
   * @param {string} dir  absolute path lexically inside this.root
   * @throws {InvalidKeyError} if it leads out of the root through a symlink
   */
  async #assertInsideRoot(dir) {
    let real;
    for (;;) {
      try {
        real = await fs.realpath(dir);
        break;
      } catch (err) {
        if (err.code === 'ENOENT' || err.code === 'ENOTDIR') {
          // No blob root yet, so nothing to escape through.
          if (dir === this.root) return;
          // Not created yet, or a component is a blob: check further up.
          dir = path.dirname(dir);
          continue;
        }
        // ELOOP: a symlink loop planted in the root; ENAMETOOLONG: over PATH_MAX.
        if (err.code === 'ELOOP' || KEY_FS_ERRORS.has(err.code)) {
          throw new InvalidKeyError(`key cannot be stored as a file: ${err.code}`);
        }
        throw err;
      }
    }
    const realRoot = await fs.realpath(this.root);
    if (real !== realRoot && !real.startsWith(realRoot + path.sep)) {
      throw new InvalidKeyError('key resolves outside the storage root through a symlink');
    }
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
    const target = this.pathOf(key);
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

      try {
        await renameInto(tmp, target, (dir) => this.#assertInsideRoot(dir));
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
   * Opens the blob stored under `key` for reading. The caller owns the
   * returned handle and must close it.
   *
   * @param {string} key  a key accepted by parseKey()
   * @returns {Promise<{ fh: fs.FileHandle, size: number } | null>} null if there is no such blob
   * @throws {InvalidKeyError} if the key cannot name a file here
   */
  async open(key) {
    const target = this.pathOf(key);
    await this.#assertInsideRoot(path.dirname(target));
    let fh;
    try {
      // O_NOFOLLOW: a symlink as the last component is not a blob (list()
      // skips it too) and must not lead out of the root.
      fh = await fs.open(target, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    } catch (err) {
      // Missing, a path component is a blob rather than a directory, or the
      // key names a symlink.
      if (err.code === 'ENOENT' || err.code === 'ENOTDIR' || err.code === 'ELOOP') return null;
      if (KEY_FS_ERRORS.has(err.code)) {
        throw new InvalidKeyError(`key cannot be stored as a file: ${err.code}`);
      }
      throw err;
    }
    // Size comes from the open handle, so it matches the bytes we will read
    // even if the blob is replaced meanwhile.
    const stat = await fh.stat().catch(async (err) => {
      await fh.close();
      throw err;
    });
    if (!stat.isFile()) {
      // A directory holding other blobs is not a blob itself.
      await fh.close();
      return null;
    }
    return { fh, size: stat.size };
  }

  /**
   * Deletes the blob stored under `key`, then removes any parent directories
   * that are left empty, so the key's path can later be reused as a blob.
   *
   * @param {string} key  a key accepted by parseKey()
   * @returns {Promise<boolean>} false if there was no such blob
   * @throws {InvalidKeyError} if the key cannot name a file here
   */
  async delete(key) {
    const target = this.pathOf(key);
    await this.#assertInsideRoot(path.dirname(target));
    try {
      // unlink() would remove a symlink itself rather than its target, but
      // a symlink is not a blob either, so leave it alone.
      if (!(await fs.lstat(target)).isFile()) return false;
      await fs.unlink(target);
    } catch (err) {
      // Missing, a path component is a blob, or the key names a directory
      // of other blobs: in each case there is no blob to delete.
      if (err.code === 'ENOENT' || err.code === 'ENOTDIR' || err.code === 'EISDIR') return false;
      if (KEY_FS_ERRORS.has(err.code)) {
        throw new InvalidKeyError(`key cannot be stored as a file: ${err.code}`);
      }
      throw err;
    }
    await this.#pruneEmptyDirs(path.dirname(target));
    return true;
  }

  async #pruneEmptyDirs(dir) {
    for (; dir !== this.root && dir.startsWith(this.root + path.sep); dir = path.dirname(dir)) {
      try {
        await fs.rmdir(dir);
      } catch {
        // Not empty (the common case), already gone, or not removable: the
        // blob itself is deleted either way, so stop here.
        return;
      }
    }
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
      // Names as raw bytes: decoding to strings would silently turn invalid
      // UTF-8 into U+FFFD and report a key that GET can never find.
      entries = await fs.readdir(dir, { withFileTypes: true, encoding: 'buffer' });
    } catch (err) {
      // Nothing stored yet, or the directory vanished while we walked.
      if (err.code === 'ENOENT') return;
      throw err;
    }
    for (const entry of entries) {
      const name = decodeName(entry.name);
      // Only a file put on disk by hand can have such a name; no key reaches it.
      if (name === null) continue;
      const segments = [...prefix, name];
      const full = path.join(dir, name);
      if (entry.isDirectory()) {
        await this.#walk(full, segments, out);
      } else if (entry.isFile()) {
        const meta = await describe(full);
        if (meta) out.push({ key: segments.join('/'), ...meta });
      }
    }
  }
}

// How many times put() recreates parent directories that a concurrent
// delete() pruned between our mkdir and rename.
const RENAME_ATTEMPTS = 5;

// Moves `tmp` to `target`, creating target's parent directories.
// `checkDir` vets the parent directory before mkdir, so nothing gets created
// through a symlink leading elsewhere, and again right before the rename.
async function renameInto(tmp, target, checkDir) {
  const dir = path.dirname(target);
  for (let attempt = 1; ; attempt++) {
    await checkDir(dir);
    try {
      await fs.mkdir(dir, { recursive: true });
      await checkDir(dir);
      await fs.rename(tmp, target);
      return;
    } catch (err) {
      // `tmp` is ours, so ENOENT means a parent directory vanished while
      // mkdir was building the chain or before the rename.
      if (err.code !== 'ENOENT' || attempt >= RENAME_ATTEMPTS) throw err;
    }
  }
}

// ignoreBOM keeps a leading U+FEFF, which is part of the name.
const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

// A file name read as bytes, decoded as a key segment; null if it is not
// valid UTF-8.
function decodeName(bytes) {
  try {
    return utf8.decode(bytes);
  } catch {
    return null;
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
