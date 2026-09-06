import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";

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

const TMP_DIR_NAME = ".syncbox-tmp";
const MAX_SEGMENT_BYTES = 255;

/** Decodes a raw (still percent-encoded) path tail, or null if malformed. */
export function decodeKey(rawTail: string): string | null {
  try {
    return decodeURIComponent(rawTail);
  } catch {
    return null;
  }
}

/**
 * Rejects anything that isn't a clean relative POSIX path: empty/absolute
 * paths, `.`/`..` segments, path separators embedded via encoding tricks,
 * bytes that can't round-trip as a UTF-8 filename (e.g. lone surrogates),
 * NUL, and segments too long for the filesystem.
 *
 * This is the first line of defense and rejects everything realistic on
 * its own. `resolveStorePath` below is a second, independent check applied
 * at actual filesystem-path construction time, so a bug here can't turn
 * into an escape.
 */
export function validateKey(key: string): boolean {
  if (key.length === 0) return false;
  if (key.includes("\0")) return false;
  if (Buffer.from(key, "utf8").toString("utf8") !== key) return false;

  const segments = key.split("/");
  for (const segment of segments) {
    if (segment.length === 0) return false;
    if (segment === "." || segment === "..") return false;
    if (Buffer.byteLength(segment, "utf8") > MAX_SEGMENT_BYTES) return false;
  }
  return true;
}

/**
 * Resolves a key to an absolute path on disk and asserts it lands strictly
 * inside dataDir. Independent of validateKey's segment-based checks: relies
 * only on Node's own path resolution (path.resolve collapses `.`/`..` and
 * normalizes separators), so it holds even if a key somehow reached this
 * point without going through validateKey first.
 */
function resolveStorePath(dataDir: string, key: string): string {
  const root = path.resolve(dataDir);
  const resolved = path.resolve(root, key);
  const rootWithSep = root.endsWith(path.sep) ? root : root + path.sep;

  if (!resolved.startsWith(rootWithSep)) {
    throw new Error(`key resolves outside the data directory: ${key}`);
  }
  return resolved;
}

/** Writes content under dataDir atomically (temp file + rename) and returns its metadata. */
export function putBlob(
  dataDir: string,
  key: string,
  content: Buffer
): PutResult {
  const destPath = resolveStorePath(dataDir, key);
  const tmpDir = path.join(dataDir, TMP_DIR_NAME);

  fs.mkdirSync(tmpDir, { recursive: true });
  fs.mkdirSync(path.dirname(destPath), { recursive: true });

  const tmpPath = path.join(
    tmpDir,
    `${crypto.randomBytes(16).toString("hex")}.tmp`
  );
  fs.writeFileSync(tmpPath, content);
  try {
    fs.renameSync(tmpPath, destPath);
  } catch (err) {
    fs.rmSync(tmpPath, { force: true });
    throw err;
  }

  return {
    key,
    sha256: crypto.createHash("sha256").update(content).digest("hex"),
    size: content.length,
  };
}

/** Reads a stored blob's content, or null if no blob exists at that key. */
export function getBlob(dataDir: string, key: string): Buffer | null {
  const srcPath = resolveStorePath(dataDir, key);

  try {
    if (!fs.statSync(srcPath).isFile()) return null;
  } catch {
    return null;
  }

  return fs.readFileSync(srcPath);
}

/** Deletes a stored blob. Returns true if it existed and was removed, false if there was no such blob. */
export function deleteBlob(dataDir: string, key: string): boolean {
  const targetPath = resolveStorePath(dataDir, key);

  try {
    if (!fs.statSync(targetPath).isFile()) return false;
  } catch {
    return false;
  }

  fs.rmSync(targetPath, { force: true });
  return true;
}

/** Lists all stored blobs with metadata. Best-effort: unreadable entries are skipped, never thrown. */
export function listBlobs(dataDir: string): BlobMeta[] {
  const results: BlobMeta[] = [];

  function walk(absDir: string, relSegments: string[]): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(absDir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (relSegments.length === 0 && entry.name === TMP_DIR_NAME) continue;

      const absPath = path.join(absDir, entry.name);
      const relPath = [...relSegments, entry.name];

      if (entry.isDirectory()) {
        walk(absPath, relPath);
      } else if (entry.isFile()) {
        try {
          const stat = fs.statSync(absPath);
          const content = fs.readFileSync(absPath);
          results.push({
            key: relPath.join("/"),
            size: stat.size,
            sha256: crypto.createHash("sha256").update(content).digest("hex"),
            modified_at: new Date(stat.mtimeMs).toISOString(),
          });
        } catch {
          // File vanished/became unreadable mid-scan; skip it rather than fail the whole listing.
        }
      }
    }
  }

  walk(dataDir, []);
  return results;
}
