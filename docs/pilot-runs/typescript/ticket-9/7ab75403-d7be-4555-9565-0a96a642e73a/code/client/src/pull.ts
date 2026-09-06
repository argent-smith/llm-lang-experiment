import * as fs from "node:fs";
import * as path from "node:path";
import { sha256 } from "./hash";
import { downloadBlob, listRemoteBlobs } from "./httpClient";

export interface PullResult {
  downloaded: string[];
  skipped: string[];
  failed: { key: string; error: string }[];
}

function localHash(absPath: string): string | undefined {
  try {
    return sha256(fs.readFileSync(absPath));
  } catch {
    return undefined;
  }
}

/**
 * Downloads every server blob that's missing locally or whose content
 * differs from the local file at the same key. A local file identical to
 * the server's version (same SHA-256) is left alone. Individual download
 * failures don't abort the run: the rest of the blobs are still attempted,
 * and failures are reported back for the caller to turn into a non-zero
 * exit code. Local files absent on the server are never touched.
 */
export async function pull(dir: string, server: string): Promise<PullResult> {
  const remote = await listRemoteBlobs(server);

  const downloaded: string[] = [];
  const skipped: string[] = [];
  const failed: { key: string; error: string }[] = [];

  for (const blob of remote) {
    const absPath = path.join(dir, ...blob.key.split("/"));

    if (localHash(absPath) === blob.sha256) {
      skipped.push(blob.key);
      continue;
    }

    try {
      const content = await downloadBlob(server, blob.key);
      fs.mkdirSync(path.dirname(absPath), { recursive: true });
      fs.writeFileSync(absPath, content);
      downloaded.push(blob.key);
    } catch (err) {
      failed.push({ key: blob.key, error: (err as Error).message });
    }
  }

  return { downloaded, skipped, failed };
}
