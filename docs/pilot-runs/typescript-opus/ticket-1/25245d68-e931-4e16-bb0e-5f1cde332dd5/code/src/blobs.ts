import { createHash, randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, open, readdir, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { Readable } from "node:stream";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

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
  const bytes = percentDecode(Buffer.from(raw, "latin1"));
  let key: string;
  try {
    key = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    throw new InvalidKeyError("key is not valid UTF-8");
  }

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

interface CachedHash {
  ino: bigint;
  size: bigint;
  mtimeNs: bigint;
  sha256: string;
}

/**
 * Blobs are stored as plain files under `<dataDir>/blobs/<key>`. Uploads are
 * streamed into `<dataDir>/tmp` and renamed into place, so readers only ever
 * see complete files and concurrent PUTs never interleave.
 */
export class BlobStore {
  private readonly blobsDir: string;
  private readonly tmpDir: string;
  /** SHA-256 of listed files, reused while inode, size and mtime match. */
  private hashCache = new Map<string, CachedHash>();

  constructor(dataDir: string) {
    this.blobsDir = join(dataDir, "blobs");
    this.tmpDir = join(dataDir, "tmp");
  }

  async put(key: string, body: Readable): Promise<PutResult> {
    await mkdir(this.tmpDir, { recursive: true });
    const tmp = join(this.tmpDir, randomUUID());
    const hash = createHash("sha256");
    let size = 0;
    try {
      await pipeline(
        body,
        new Transform({
          transform(chunk: Buffer, _encoding, callback) {
            hash.update(chunk);
            size += chunk.length;
            callback(null, chunk);
          },
        }),
        createWriteStream(tmp, { flags: "wx" }),
      );

      const target = join(this.blobsDir, ...key.split("/"));
      try {
        await mkdir(dirname(target), { recursive: true });
        await rename(tmp, target);
      } catch (err) {
        if (KEY_CONFLICT_CODES.has((err as NodeJS.ErrnoException).code ?? "")) {
          throw new InvalidKeyError(`key cannot be stored: ${(err as Error).message}`);
        }
        throw err;
      }
    } catch (err) {
      await rm(tmp, { force: true });
      throw err;
    }
    return { key, sha256: hash.digest("hex"), size };
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
      entries = await readdir(dir, { withFileTypes: true });
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return;
      throw err;
    }
    for (const entry of entries) {
      const key = prefix + entry.name;
      const path = join(dir, entry.name);
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
      // Removed or replaced by a directory since readdir: not a blob any more.
      const code = (err as NodeJS.ErrnoException).code;
      if (code === "ENOENT" || code === "EISDIR") return undefined;
      throw err;
    }
    try {
      // Stat and hash through the same handle, so a concurrent overwrite
      // can't pair one version's size with another version's hash.
      const st = await handle.stat({ bigint: true });
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
        modified_at: new Date(Number(st.mtimeNs / 1_000_000n)).toISOString(),
      };
    } finally {
      await handle.close();
    }
  }
}
