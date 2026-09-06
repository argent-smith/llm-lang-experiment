import * as fs from "node:fs";
import * as path from "node:path";
import { sha256 } from "./hash";
import { listRemoteBlobs, uploadBlob } from "./httpClient";
import { walkFiles } from "./walk";

export interface PushResult {
  uploaded: string[];
  skipped: string[];
  failed: { key: string; error: string }[];
}

/**
 * Uploads every local file under dir whose content isn't already present
 * on the server under the same key. A file identical to the server's
 * version (same SHA-256) is left alone. Individual upload failures don't
 * abort the run: the rest of the files are still attempted, and failures
 * are reported back for the caller to turn into a non-zero exit code.
 */
export async function push(dir: string, server: string): Promise<PushResult> {
  const remote = await listRemoteBlobs(server);
  const remoteHashes = new Map(remote.map((blob) => [blob.key, blob.sha256]));

  const localKeys = walkFiles(dir);

  const uploaded: string[] = [];
  const skipped: string[] = [];
  const failed: { key: string; error: string }[] = [];

  for (const key of localKeys) {
    const absPath = path.join(dir, ...key.split("/"));
    let content: Buffer;
    try {
      content = fs.readFileSync(absPath);
    } catch (err) {
      failed.push({
        key,
        error: `could not read local file: ${(err as Error).message}`,
      });
      continue;
    }

    if (remoteHashes.get(key) === sha256(content)) {
      skipped.push(key);
      continue;
    }

    try {
      await uploadBlob(server, key, content);
      uploaded.push(key);
    } catch (err) {
      failed.push({ key, error: (err as Error).message });
    }
  }

  return { uploaded, skipped, failed };
}
