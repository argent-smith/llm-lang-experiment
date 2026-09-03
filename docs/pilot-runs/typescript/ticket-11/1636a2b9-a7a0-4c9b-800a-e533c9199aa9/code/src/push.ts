import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join, relative, sep } from "node:path";
import { fetchBlobList, uploadBlob, type FileFailure, type NetOptions } from "./net.js";

export interface PushResult {
  uploaded: string[];
  skipped: string[];
  failed: FileFailure[];
}

/**
 * Uploads every file under `dir` that is missing on the server or whose
 * content differs from the server's version (by SHA-256). Files that already
 * match the server are left alone.
 *
 * A file that fails to read or upload (local I/O error, network error, or a
 * 5xx from the server) is recorded in `failed` rather than aborting the rest
 * - the remaining files are still attempted.
 */
export async function push(
  dir: string,
  server: string,
  opts: NetOptions = {},
): Promise<PushResult> {
  const [localFiles, remoteBlobs] = await Promise.all([
    walkFiles(dir),
    fetchBlobList(server, opts),
  ]);

  const remoteSha256ByKey = new Map(remoteBlobs.map((b) => [b.key, b.sha256]));

  const uploaded: string[] = [];
  const skipped: string[] = [];
  const failed: FileFailure[] = [];

  for (const { key, path } of localFiles) {
    try {
      const content = await readFile(path);
      const sha256 = createHash("sha256").update(content).digest("hex");

      if (remoteSha256ByKey.get(key) === sha256) {
        skipped.push(key);
        continue;
      }

      await uploadBlob(server, key, content, opts);
      uploaded.push(key);
    } catch (err) {
      failed.push({ key, message: err instanceof Error ? err.message : String(err) });
    }
  }

  failed.sort((a, b) => a.key.localeCompare(b.key));

  return { uploaded, skipped, failed };
}

interface LocalFile {
  key: string;
  path: string;
}

async function walkFiles(root: string, dir = root): Promise<LocalFile[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files: LocalFile[] = [];
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walkFiles(root, fullPath)));
    } else if (entry.isFile()) {
      files.push({
        key: toPosixKey(relative(root, fullPath)),
        path: fullPath,
      });
    }
  }
  return files;
}

function toPosixKey(relativePath: string): string {
  return sep === "/" ? relativePath : relativePath.split(sep).join("/");
}
