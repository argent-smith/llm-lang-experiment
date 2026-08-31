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

  return {
    sha256: createHash("sha256").update(body).digest("hex"),
    size: body.length,
  };
}

export async function getBlob(
  dataDir: string,
  key: string,
): Promise<Buffer | undefined> {
  try {
    return await readFile(keyToPath(dataDir, key));
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      return undefined;
    }
    throw err;
  }
}

export async function deleteBlob(
  dataDir: string,
  key: string,
): Promise<boolean> {
  try {
    await unlink(keyToPath(dataDir, key));
    return true;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      return false;
    }
    throw err;
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
