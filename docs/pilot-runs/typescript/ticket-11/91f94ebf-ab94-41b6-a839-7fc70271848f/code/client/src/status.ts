import * as fs from "node:fs";
import * as path from "node:path";
import { sha256 } from "./hash";
import { listRemoteBlobs } from "./httpClient";
import { walkFiles } from "./walk";

export interface StatusResult {
  toUpload: string[];
  toDownload: string[];
  unchanged: string[];
  failed: { key: string; error: string }[];
}

/**
 * Read-only comparison of the local directory against the server's blob
 * list: reports what push would upload and what pull would download,
 * without performing either or touching any file. A key that diverges on
 * both sides lands in both toUpload and toDownload — status mirrors what
 * each unidirectional command would independently do; picking a single
 * winner is sync's conflict-resolution job, not status's. A local file
 * that can't be read is reported as a failure and left out of the
 * comparison rather than aborting the whole command.
 */
export async function status(
  dir: string,
  server: string
): Promise<StatusResult> {
  const remote = await listRemoteBlobs(server);
  const remoteHashes = new Map(remote.map((blob) => [blob.key, blob.sha256]));

  const localKeys = walkFiles(dir);
  const localHashes = new Map<string, string>();
  const failed: { key: string; error: string }[] = [];
  for (const key of localKeys) {
    try {
      localHashes.set(
        key,
        sha256(fs.readFileSync(path.join(dir, ...key.split("/"))))
      );
    } catch (err) {
      failed.push({
        key,
        error: `could not read local file: ${(err as Error).message}`,
      });
    }
  }

  const allKeys = new Set([...localHashes.keys(), ...remoteHashes.keys()]);

  const toUpload: string[] = [];
  const toDownload: string[] = [];
  const unchanged: string[] = [];

  for (const key of [...allKeys].sort()) {
    const local = localHashes.get(key);
    const remote = remoteHashes.get(key);

    if (local !== undefined && local !== remote) {
      toUpload.push(key);
    }
    if (remote !== undefined && remote !== local) {
      toDownload.push(key);
    }
    if (local !== undefined && local === remote) {
      unchanged.push(key);
    }
  }

  return { toUpload, toDownload, unchanged, failed };
}
