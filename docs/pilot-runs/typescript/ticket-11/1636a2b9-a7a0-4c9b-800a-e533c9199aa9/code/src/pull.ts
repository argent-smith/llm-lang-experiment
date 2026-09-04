import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { downloadBlob, fetchBlobList, type FileFailure, type NetOptions } from "./net.js";

export interface PullResult {
  downloaded: string[];
  skipped: string[];
  failed: FileFailure[];
}

/**
 * Downloads every blob on the server that is missing under `dir` or whose
 * content differs from the local file's SHA-256, writing each one to the
 * relative POSIX path given by its key (creating subdirectories as needed).
 * Files that already match the server are left alone. Local files absent
 * from the server are never touched or removed.
 *
 * A blob that fails to download or write locally (network error, a 5xx from
 * the server, or a local I/O error) is recorded in `failed` rather than
 * aborting the rest - the remaining blobs are still attempted.
 */
export async function pull(
  dir: string,
  server: string,
  opts: NetOptions = {},
): Promise<PullResult> {
  const remoteBlobs = await fetchBlobList(server, opts);

  const downloaded: string[] = [];
  const skipped: string[] = [];
  const failed: FileFailure[] = [];

  for (const blob of remoteBlobs) {
    try {
      const localSha256 = await localFileSha256(dir, blob.key);
      if (localSha256 === blob.sha256) {
        skipped.push(blob.key);
        continue;
      }

      const content = await downloadBlob(server, blob.key, opts);
      await writeLocalFile(dir, blob.key, content);
      downloaded.push(blob.key);
    } catch (err) {
      failed.push({
        key: blob.key,
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }

  failed.sort((a, b) => a.key.localeCompare(b.key));

  return { downloaded, skipped, failed };
}

function keyToLocalPath(dir: string, key: string): string {
  return join(dir, ...key.split("/"));
}

async function localFileSha256(
  dir: string,
  key: string,
): Promise<string | undefined> {
  try {
    const content = await readFile(keyToLocalPath(dir, key));
    return createHash("sha256").update(content).digest("hex");
  } catch {
    return undefined;
  }
}

async function writeLocalFile(
  dir: string,
  key: string,
  content: Buffer,
): Promise<void> {
  const filePath = keyToLocalPath(dir, key);
  await mkdir(dirname(filePath), { recursive: true });
  await writeFile(filePath, content);
}
