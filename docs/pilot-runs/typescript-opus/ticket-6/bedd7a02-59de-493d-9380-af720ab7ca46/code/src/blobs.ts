import { createHash, randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { lstat, mkdir, open, readdir, rename, rm, rmdir, stat, unlink, type FileHandle } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import type { Readable } from "node:stream";

/** Longest file name component most Linux file systems accept, in bytes. */
const MAX_SEGMENT_BYTES = 255;

export interface BlobMeta {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
}

export interface PutResult {
  key: string;
  sha256: string;
  size: number;
}

/** The key can't be stored on this server; maps to 400. */
export class InvalidKeyError extends Error {
  override name = "InvalidKeyError";
}

/**
 * Turns the raw (still percent-encoded) part of the request path after
 * `/blobs/` into a blob key, or throws InvalidKeyError. Accepted keys are
 * relative POSIX paths of non-empty, non-dot segments that decode to valid
 * UTF-8 (so lone surrogates are rejected too) and contain no NUL bytes.
 */
export function parseKey(raw: string): string {
  // req.url carries the request-target bytes as latin1 characters.
  const key = decodeUtf8(percentDecode(Buffer.from(raw, "latin1")));
  if (key === undefined) throw new InvalidKeyError("key is not valid UTF-8");
  if (key === "") throw new InvalidKeyError("key is empty");
  if (key.includes("\0")) throw new InvalidKeyError("key contains a NUL byte");
  if (key.startsWith("/")) throw new InvalidKeyError("key must be a relative path");
  for (const segment of key.split("/")) {
    if (segment === "" || segment === "." || segment === "..") {
      throw new InvalidKeyError("key contains an empty, '.' or '..' path segment");
    }
    if (Buffer.byteLength(segment) > MAX_SEGMENT_BYTES) {
      throw new InvalidKeyError("key contains a path segment that is too long");
    }
  }
  return key;
}

/** Strict UTF-8 decoding: undefined rather than replacement characters. */
function decodeUtf8(bytes: Uint8Array): string | undefined {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

function percentDecode(input: Buffer): Buffer {
  const out = Buffer.alloc(input.length);
  let n = 0;
  for (let i = 0; i < input.length; i++) {
    const byte = input[i]!;
    if (byte !== 0x25 /* % */) {
      out[n++] = byte;
      continue;
    }
    const hex = input.subarray(i + 1, i + 3).toString("latin1");
    if (!/^[0-9a-fA-F]{2}$/.test(hex)) {
      throw new InvalidKeyError("key contains a malformed percent-escape");
    }
    out[n++] = parseInt(hex, 16);
    i += 2;
  }
  return out.subarray(0, n);
}

/**
 * File system errors that mean "this key can't be a file here" rather than
 * a server fault: the name is too long or unrepresentable, or it collides
 * with an existing key (`a` vs `a/b`).
 */
const KEY_CONFLICT_CODES = new Set(["ENAMETOOLONG", "EILSEQ", "EINVAL", "ENOTDIR", "EISDIR", "EEXIST"]);

/**
 * File system errors that mean "there is no blob under this key". ELOOP is
 * what open() with O_NOFOLLOW reports for a symbolic link: links aren't
 * blobs (list() doesn't report them either).
 */
const NOT_FOUND_CODES = new Set(["ENOENT", "ENOTDIR", "EISDIR", "ENAMETOOLONG", "EILSEQ", "EINVAL", "ELOOP"]);

/**
 * File system errors that mean an entry list() saw in readdir is gone by the
 * time it gets to it: removed, or a directory turned into a file (or vice
 * versa) by concurrent DELETEs and PUTs.
 */
const VANISHED_CODES = new Set(["ENOENT", "ENOTDIR", "EISDIR"]);

/** How often put() retries when its parent directory vanishes under it. */
const MAX_PUT_ATTEMPTS = 10;

const NS_PER_MS = 1_000_000n;

/**
 * Formats a file time as ISO 8601 UTC, rounded to the nearest millisecond the
 * way fs.Stats#mtime is: file systems store a time set with utimes() slightly
 * below the requested millisecond, and truncating would make a client that
 * copies modified_at onto its file see a different time come back.
 */
function isoFromNs(ns: bigint): string {
  const shifted = ns + NS_PER_MS / 2n;
  // Floor division, so times before 1970 round the same way.
  const ms = shifted / NS_PER_MS - (shifted % NS_PER_MS < 0n ? 1n : 0n);
  return new Date(Number(ms)).toISOString();
}

export interface OpenBlob {
  size: number;
  /** Open for reading; the caller is responsible for closing it. */
  handle: FileHandle;
}

interface CachedHash {
  ino: bigint;
  size: bigint;
  mtimeNs: bigint;
  sha256: string;
}

/**
 * Blobs are stored as plain files under `<dataDir>/blobs/<key>`. Uploads are
 * streamed into `<dataDir>/tmp` and renamed into place, so readers only ever
 * see complete files and concurrent PUTs never interleave. `tmp` lies outside
 * the tree that keys resolve into and list() walks, so uploads in progress
 * are neither listed nor served.
 */
export class BlobStore {
  private readonly blobsDir: string;
  private readonly tmpDir: string;
  /** SHA-256 of listed files, reused while inode, size and mtime match. */
  private hashCache = new Map<string, CachedHash>();

  constructor(dataDir: string) {
    // Absolute, so that resolved key paths can be checked against it.
    this.blobsDir = resolve(dataDir, "blobs");
    this.tmpDir = resolve(dataDir, "tmp");
  }

  /**
   * Prepares the store for serving: creates its directories, makes sure
   * uploads and blobs share a file system (otherwise rename() would fail with
   * EXDEV instead of swapping files atomically) and removes uploads left
   * behind by a server that was killed mid-request. Only one server process
   * is expected per data dir, so nothing in `tmp` can still be in use.
   */
  async init(): Promise<void> {
    await mkdir(this.blobsDir, { recursive: true });
    await mkdir(this.tmpDir, { recursive: true });
    const [blobs, tmp] = await Promise.all([stat(this.blobsDir), stat(this.tmpDir)]);
    if (blobs.dev !== tmp.dev) {
      throw new Error(`${this.tmpDir} and ${this.blobsDir} must be on the same file system`);
    }
    for (const name of await readdir(this.tmpDir)) {
      await rm(join(this.tmpDir, name), { recursive: true, force: true });
    }
  }

  /**
   * Stores `body` under `key`. The upload goes to a fresh file in `tmp` that is
   * renamed over the target only once it is complete and flushed, so a reader
   * opening the key at any moment gets either the previous version or this
   * one in full, and concurrent PUTs to one key never mix: the last rename
   * wins. The temporary file is removed whenever the upload fails, including
   * when the client disconnects mid-body.
   */
  async put(key: string, body: Readable): Promise<PutResult> {
    // Refuse keys outside the store before accepting any data.
    await this.pathOf(key);
    await mkdir(this.tmpDir, { recursive: true });
    const tmp = join(this.tmpDir, randomUUID());
    const hash = createHash("sha256");
    let size = 0;
    // Created up front rather than lazily by a write stream, so the cleanup
    // below can't run before the file exists and miss it.
    const handle = await open(tmp, "wx");
    try {
      try {
        for await (const data of body as AsyncIterable<Buffer | string>) {
          const chunk = typeof data === "string" ? Buffer.from(data) : data;
          hash.update(chunk);
          size += chunk.length;
          for (let offset = 0; offset < chunk.length; ) {
            offset += (await handle.write(chunk, offset)).bytesWritten;
          }
        }
        // Otherwise a crash shortly after the rename could leave the key
        // pointing at a file whose data never reached the disk.
        await handle.datasync();
      } finally {
        await handle.close();
      }

      for (let attempt = 1; ; attempt++) {
        // Resolved right before use rather than before the (possibly long)
        // upload, to keep the window for swapping in a link small.
        const target = await this.pathOf(key);
        try {
          await mkdir(dirname(target), { recursive: true });
          await rename(tmp, target);
          break;
        } catch (err) {
          const code = (err as NodeJS.ErrnoException).code ?? "";
          if (KEY_CONFLICT_CODES.has(code)) {
            throw new InvalidKeyError(`key cannot be stored: ${(err as Error).message}`);
          }
          // A concurrent delete pruned the parent directory between mkdir
          // and rename: recreate it and try again.
          if (code === "ENOENT" && attempt < MAX_PUT_ATTEMPTS) continue;
          throw err;
        }
      }
    } catch (err) {
      await rm(tmp, { force: true });
      throw err;
    }
    return { key, sha256: hash.digest("hex"), size };
  }

  /** Opens the blob stored under `key`, or returns undefined if there is none. */
  async open(key: string): Promise<OpenBlob | undefined> {
    const target = await this.pathOf(key);
    let handle;
    try {
      handle = await open(target, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    } catch (err) {
      if (NOT_FOUND_CODES.has((err as NodeJS.ErrnoException).code ?? "")) return undefined;
      throw err;
    }
    try {
      // Directories along a stored key's path (`docs` for `docs/readme.txt`)
      // open fine on Linux but aren't blobs.
      const st = await handle.stat();
      if (!st.isFile()) {
        await handle.close();
        return undefined;
      }
      return { size: st.size, handle };
    } catch (err) {
      await handle.close();
      throw err;
    }
  }

  /** Deletes the blob stored under `key`; returns false if there is none. */
  async delete(key: string): Promise<boolean> {
    const target = await this.pathOf(key);
    try {
      await unlink(target);
    } catch (err) {
      // Directories of other keys aren't blobs either; unlink() reports them
      // as EISDIR on Linux and EPERM on some other systems.
      const code = (err as NodeJS.ErrnoException).code ?? "";
      if (NOT_FOUND_CODES.has(code) || code === "EPERM") return false;
      throw err;
    }
    await this.pruneEmptyDirs(dirname(target));
    return true;
  }

  /**
   * Removes directories left empty by a delete, up to (not including) the
   * store root, so that `docs` can be stored as a key again once
   * `docs/readme.txt` is gone. Best effort: stops at the first directory that
   * is not empty or can't be removed.
   */
  private async pruneEmptyDirs(dir: string): Promise<void> {
    while (dir !== this.blobsDir && dir.startsWith(this.blobsDir + sep)) {
      try {
        await rmdir(dir);
      } catch {
        return;
      }
      dir = dirname(dir);
    }
  }

  /**
   * Maps a key to its file in the store, or throws InvalidKeyError if that
   * file would not be strictly inside the store root. parseKey() already
   * rejects `..`, `.`, empty and absolute keys; this doesn't rely on it and
   * checks the resulting path itself: once resolved it must stay below the
   * root, and none of the directories on the way to it may be a symbolic
   * link (keys can't create one, but someone with access to the data dir
   * can, and it could point anywhere). The final component isn't checked
   * here: open() refuses to follow it, rename() and unlink() act on the link
   * itself.
   *
   * Links are checked, not locked out: one swapped in between this check and
   * the operation that follows goes unnoticed. That again takes direct write
   * access to the data dir, which no key can provide.
   */
  private async pathOf(key: string): Promise<string> {
    const target = resolve(this.blobsDir, ...key.split("/"));
    if (!target.startsWith(this.blobsDir + sep)) {
      throw new InvalidKeyError("key resolves to a path outside the store");
    }
    let dir = this.blobsDir;
    for (const segment of relative(this.blobsDir, target).split(sep).slice(0, -1)) {
      dir = join(dir, segment);
      let st;
      try {
        st = await lstat(dir);
      } catch (err) {
        // Nothing further down exists, so there are no links to find; the
        // operation itself reports the missing (or unrepresentable) path.
        if (NOT_FOUND_CODES.has((err as NodeJS.ErrnoException).code ?? "")) break;
        throw err;
      }
      if (st.isSymbolicLink()) {
        throw new InvalidKeyError("key leads through a symbolic link in the store");
      }
      // A file where a directory should be: likewise left to the operation.
      if (!st.isDirectory()) break;
    }
    return target;
  }

  async list(): Promise<BlobMeta[]> {
    const blobs: BlobMeta[] = [];
    const cache = new Map<string, CachedHash>();
    await this.walk(this.blobsDir, "", blobs, cache);
    this.hashCache = cache;
    return blobs.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  }

  private async walk(dir: string, prefix: string, out: BlobMeta[], cache: Map<string, CachedHash>): Promise<void> {
    let entries;
    try {
      // Raw names: decoding them leniently would list keys GET can't find.
      entries = await readdir(dir, { withFileTypes: true, encoding: "buffer" });
    } catch (err) {
      if (VANISHED_CODES.has((err as NodeJS.ErrnoException).code ?? "")) return;
      throw err;
    }
    for (const entry of entries) {
      // A file put into the store from outside may have a name that isn't
      // valid UTF-8; no key can address it, so it isn't a blob.
      const name = decodeUtf8(entry.name);
      if (name === undefined) continue;
      const key = prefix + name;
      const path = join(dir, name);
      if (entry.isDirectory()) {
        await this.walk(path, `${key}/`, out, cache);
      } else if (entry.isFile()) {
        const meta = await this.describe(key, path, cache);
        if (meta !== undefined) out.push(meta);
      }
    }
  }

  private async describe(key: string, path: string, cache: Map<string, CachedHash>): Promise<BlobMeta | undefined> {
    let handle;
    try {
      handle = await open(path, "r");
    } catch (err) {
      if (VANISHED_CODES.has((err as NodeJS.ErrnoException).code ?? "")) return undefined;
      throw err;
    }
    try {
      // Stat and hash through the same handle, so a concurrent overwrite
      // can't pair one version's size with another version's hash.
      const st = await handle.stat({ bigint: true });
      // Replaced by a directory since readdir (which opens fine on Linux).
      if (!st.isFile()) return undefined;
      const cached = this.hashCache.get(key);
      let entry: CachedHash;
      if (cached !== undefined && cached.ino === st.ino && cached.size === st.size && cached.mtimeNs === st.mtimeNs) {
        entry = cached;
      } else {
        const hash = createHash("sha256");
        for await (const chunk of handle.createReadStream({ autoClose: false })) {
          hash.update(chunk as Buffer);
        }
        entry = { ino: st.ino, size: st.size, mtimeNs: st.mtimeNs, sha256: hash.digest("hex") };
      }
      cache.set(key, entry);
      return {
        key,
        size: Number(st.size),
        sha256: entry.sha256,
        modified_at: isoFromNs(st.mtimeNs),
      };
    } finally {
      await handle.close();
    }
  }
}
