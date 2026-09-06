import * as fs from "node:fs";
import * as path from "node:path";
import { sha256 } from "./hash";
import { listRemoteBlobs } from "./httpClient";
import { walkFiles } from "./walk";

export interface StatusResult {
  toUpload: string[];
  toDownload: string[];
  unchanged: string[];
}

/**
 * Read-only comparison of the local directory against the server's blob
 * list: reports what push would upload and what pull would download,
 * without performing either or touching any file. A key that diverges on
 * both sides lands in both toUpload and toDownload — status mirrors what
 * each unidirectional command would independently do; picking a single
 * winner is sync's conflict-resolution job, not status's.
 */
export async function status(
  dir: string,
  server: string
): Promise<StatusResult> {
  const remote = await listRemoteBlobs(server);
  const remoteHashes = new Map(remote.map((blob) => [blob.key, blob.sha256]));

  const localKeys = walkFiles(dir);
  const localHashes = new Map(
    localKeys.map((key) => [
      key,
      sha256(fs.readFileSync(path.join(dir, ...key.split("/")))),
    ])
  );

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

  return { toUpload, toDownload, unchanged };
}
