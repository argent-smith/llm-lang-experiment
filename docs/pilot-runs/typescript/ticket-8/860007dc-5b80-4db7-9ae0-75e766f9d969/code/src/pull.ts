import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { BlobMeta } from "./storage.js";

const REQUEST_TIMEOUT_MS = 30_000;

export interface PullResult {
  downloaded: string[];
  skipped: string[];
}

/**
 * Downloads every blob on the server that is missing under `dir` or whose
 * content differs from the local file's SHA-256, writing each one to the
 * relative POSIX path given by its key (creating subdirectories as needed).
 * Files that already match the server are left alone. Local files absent
 * from the server are never touched or removed.
 */
export async function pull(dir: string, server: string): Promise<PullResult> {
  const remoteBlobs = await fetchBlobList(server);

  const downloaded: string[] = [];
  const skipped: string[] = [];

  for (const blob of remoteBlobs) {
    const localSha256 = await localFileSha256(dir, blob.key);
    if (localSha256 === blob.sha256) {
      skipped.push(blob.key);
      continue;
    }

    const content = await downloadBlob(server, blob.key);
    await writeLocalFile(dir, blob.key, content);
    downloaded.push(blob.key);
  }

  return { downloaded, skipped };
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

function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

async function fetchBlobList(server: string): Promise<BlobMeta[]> {
  const res = await fetch(`${server}/blobs`, {
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`GET /blobs failed with status ${res.status}`);
  }
  return (await res.json()) as BlobMeta[];
}

async function downloadBlob(server: string, key: string): Promise<Buffer> {
  const res = await fetch(`${server}/blobs/${encodeKey(key)}`, {
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`GET /blobs/${key} failed with status ${res.status}`);
  }
  return Buffer.from(await res.arrayBuffer());
}
