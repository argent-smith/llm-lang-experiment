import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join, relative, sep } from "node:path";
import { fetchBlobList, type FileFailure, type NetOptions } from "./net.js";

export interface StatusResult {
  /** Locally present, missing or differing on the server: what `push` would upload. */
  toUpload: string[];
  /** Present on the server, missing or differing locally: what `pull` would download. */
  toDownload: string[];
  /** Identical on both sides. */
  unchanged: string[];
  /** Local files that couldn't be read, so no comparison could be made for them. */
  failed: FileFailure[];
}

/**
 * Compares `dir` against the server's blob list by key and SHA-256, without
 * changing either side: no PUT/DELETE against the server, no local file
 * writes. A file whose content diverges on both sides appears in both
 * `toUpload` and `toDownload` — status reports what push and pull would each
 * do independently; picking a winner is sync's job (a later ticket).
 */
export async function status(
  dir: string,
  server: string,
  opts: NetOptions = {},
): Promise<StatusResult> {
  const [localFiles, remoteBlobs] = await Promise.all([
    walkFiles(dir),
    fetchBlobList(server, opts),
  ]);

  const remoteSha256ByKey = new Map(remoteBlobs.map((b) => [b.key, b.sha256]));
  const localSha256ByKey = new Map<string, string>();
  const failed: FileFailure[] = [];
  for (const { key, path } of localFiles) {
    try {
      const content = await readFile(path);
      localSha256ByKey.set(key, createHash("sha256").update(content).digest("hex"));
    } catch (err) {
      failed.push({ key, message: err instanceof Error ? err.message : String(err) });
    }
  }

  const toUpload: string[] = [];
  const toDownload: string[] = [];
  const unchanged: string[] = [];

  const allKeys = new Set([...localSha256ByKey.keys(), ...remoteSha256ByKey.keys()]);
  for (const key of allKeys) {
    const localSha256 = localSha256ByKey.get(key);
    const remoteSha256 = remoteSha256ByKey.get(key);
    const matches = localSha256 !== undefined && localSha256 === remoteSha256;

    if (matches) {
      unchanged.push(key);
      continue;
    }
    if (localSha256 !== undefined && localSha256 !== remoteSha256) {
      toUpload.push(key);
    }
    if (remoteSha256 !== undefined && remoteSha256 !== localSha256) {
      toDownload.push(key);
    }
  }

  toUpload.sort();
  toDownload.sort();
  unchanged.sort();
  failed.sort((a, b) => a.key.localeCompare(b.key));

  return { toUpload, toDownload, unchanged, failed };
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
