import { createHash, randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

/**
 * Marker embedded in temp-file names used for atomic writes. Files whose
 * name contains this marker are in-progress writes, not finished blobs, so
 * `listBlobs` must skip them and they must never be reachable through a
 * `key` a client controls.
 */
const TEMP_FILE_MARKER = ".syncbox-tmp-";

export interface PutResult {
  sha256: string;
  size: number;
}

export interface BlobMeta {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
}

/** Thrown for a `key` that must be rejected with 400 (traversal, absolute path, unrepresentable). */
export class InvalidKeyError extends Error {}

/**
 * Resolves `key` to an absolute path on disk, guaranteed to stay inside `dataDir`.
 * Containment is checked on the *resolved* path rather than by scanning for ".."
 * substrings, so it also catches indirect escapes (e.g. "a/../../etc/passwd").
 */
export function keyToPath(dataDir: string, key: string): string {
  if (key.length === 0) {
    throw new InvalidKeyError("key must not be empty");
  }
  if (key.includes("\0")) {
    throw new InvalidKeyError("key must not contain a null byte");
  }
  if (!isWellFormed(key)) {
    throw new InvalidKeyError("key is not a well-formed string");
  }
  if (isAbsolute(key)) {
    throw new InvalidKeyError("key must not be an absolute path");
  }

  const root = resolve(dataDir);
  const target = resolve(root, key);
  const rel = relative(root, target);

  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new InvalidKeyError("key escapes the storage root");
  }

  return target;
}

function isWellFormed(value: string): boolean {
  return Buffer.from(value, "utf8").toString("utf8") === value;
}

export async function putBlob(
  dataDir: string,
  key: string,
  body: Buffer,
): Promise<PutResult> {
  const filePath = keyToPath(dataDir, key);

  // Structural validation (in keyToPath above) can't catch every way a key
  // is unusable — some byte sequences are well-formed UTF-8 and stay inside
  // the storage root, yet the underlying filesystem/OS still refuses to
  // create a file or directory with that name (encoding restrictions,
  // reserved characters, length limits, ...), surfacing as an EIO/ENOENT/
  // EILSEQ-style error out of mkdir/writeFile/rename. From the API's point
  // of view that's just an unwritable key, not a server fault, so any
  // failure in this disk-write pipeline is reported the same way structural
  // rejection is: 400 via InvalidKeyError, never an uncaught 500.
  try {
    await mkdir(dirname(filePath), { recursive: true });

    // Write to a temp file in the same directory (so it's on the same
    // filesystem as `filePath`, making the rename below atomic rather than a
    // copy) and rename it into place. Concurrent PUTs of the same key each
    // get their own temp file and race only on the final rename, which the
    // filesystem guarantees is all-or-nothing — a concurrent GET can only
    // ever observe the fully-old or fully-new content, never a partial write.
    const tempPath = `${filePath}${TEMP_FILE_MARKER}${randomUUID()}`;
    try {
      await writeFile(tempPath, body);
      await rename(tempPath, filePath);
    } catch (err) {
      await unlink(tempPath).catch(() => {});
      throw err;
    }
  } catch (err) {
    throw new InvalidKeyError(
      `key cannot be written to storage: ${(err as Error).message}`,
    );
  }

  return {
    sha256: createHash("sha256").update(body).digest("hex"),
    size: body.length,
  };
}

export async function getBlob(
  dataDir: string,
  key: string,
): Promise<Buffer | undefined> {
  // keyToPath can still throw here (InvalidKeyError) and that's meant to
  // propagate to the caller as 400. Once we have a path, though, any
  // failure reading it (missing file, or a key whose on-disk form the
  // filesystem/OS refuses to stat or open at all - long combining-mark
  // runs, astral-plane characters, stray C1/Latin-1 bytes, ...) means
  // there is no readable blob at this key, exactly like ENOENT. A key
  // that can never be represented on disk could never have been written
  // successfully by putBlob either, so "not found" is the accurate answer.
  const filePath = keyToPath(dataDir, key);
  try {
    return await readFile(filePath);
  } catch {
    return undefined;
  }
}

export async function deleteBlob(
  dataDir: string,
  key: string,
): Promise<boolean> {
  // Same reasoning as getBlob: keyToPath's InvalidKeyError still propagates
  // as 400, but any OS-level failure removing an existing path is treated
  // as "nothing to delete" rather than an uncaught 500.
  const filePath = keyToPath(dataDir, key);
  try {
    await unlink(filePath);
    return true;
  } catch {
    return false;
  }
}

export async function listBlobs(dataDir: string): Promise<BlobMeta[]> {
  const filePaths = await walkFiles(dataDir);
  const blobs = await Promise.all(
    filePaths.map(async (filePath) => {
      const [body, stats] = await Promise.all([
        readFile(filePath),
        stat(filePath),
      ]);
      return {
        key: toPosixKey(relative(dataDir, filePath)),
        size: stats.size,
        sha256: createHash("sha256").update(body).digest("hex"),
        modified_at: stats.mtime.toISOString(),
      };
    }),
  );

  blobs.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return blobs;
}

async function walkFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walkFiles(fullPath)));
    } else if (entry.isFile() && !entry.name.includes(TEMP_FILE_MARKER)) {
      files.push(fullPath);
    }
  }
  return files;
}

function toPosixKey(relativePath: string): string {
  return sep === "/" ? relativePath : relativePath.split(sep).join("/");
}
