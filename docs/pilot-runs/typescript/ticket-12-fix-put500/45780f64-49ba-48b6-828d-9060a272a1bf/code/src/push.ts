import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join, relative, sep } from "node:path";
import type { BlobMeta } from "./storage.js";

const REQUEST_TIMEOUT_MS = 30_000;

export interface PushResult {
  uploaded: string[];
  skipped: string[];
}

/**
 * Uploads every file under `dir` that is missing on the server or whose
 * content differs from the server's version (by SHA-256). Files that already
 * match the server are left alone.
 */
export async function push(dir: string, server: string): Promise<PushResult> {
  const [localFiles, remoteBlobs] = await Promise.all([
    walkFiles(dir),
    fetchBlobList(server),
  ]);

  const remoteSha256ByKey = new Map(remoteBlobs.map((b) => [b.key, b.sha256]));

  const uploaded: string[] = [];
  const skipped: string[] = [];

  for (const { key, path } of localFiles) {
    const content = await readFile(path);
    const sha256 = createHash("sha256").update(content).digest("hex");

    if (remoteSha256ByKey.get(key) === sha256) {
      skipped.push(key);
      continue;
    }

    await uploadBlob(server, key, content);
    uploaded.push(key);
  }

  return { uploaded, skipped };
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

async function uploadBlob(
  server: string,
  key: string,
  content: Buffer,
): Promise<void> {
  const res = await fetch(`${server}/blobs/${encodeKey(key)}`, {
    method: "PUT",
    body: content,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`PUT /blobs/${key} failed with status ${res.status}`);
  }
}
