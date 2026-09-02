import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, sep } from "node:path";
import type { BlobMeta } from "./storage.js";

const REQUEST_TIMEOUT_MS = 30_000;

// Where sync keeps track of the last known common state between runs, so it
// can tell "changed on one side" (safe to copy over) apart from a real
// conflict (changed on both sides). Lives inside `dir` because that's the
// only thing that persists between separate `run-client sync` invocations
// (each one is a fresh, otherwise-throwaway container).
const MANIFEST_DIR_NAME = ".syncbox";
const MANIFEST_FILE_NAME = "manifest.json";

export interface SyncResult {
  uploaded: string[];
  downloaded: string[];
  unchanged: string[];
}

interface Manifest {
  /** key -> SHA-256 both sides agreed on as of the end of the last successful sync. */
  entries: Record<string, string>;
}

interface LocalEntry {
  path: string;
  content: Buffer;
  sha256: string;
}

/**
 * Two-way syncs `dir` with the server by key and SHA-256: a file present on
 * only one side, or differing between the two, is copied to the other side.
 * A file that changed on both sides since the last successful sync (tracked
 * in a manifest under `dir/.syncbox/`) is a conflict, resolved by the fixed
 * rule: the newer of local mtime / remote modified_at wins, local wins on a
 * tie. Never deletes on either side - a file missing on one side is copied
 * over, not used as a reason to remove it from the other.
 */
export async function sync(dir: string, server: string): Promise<SyncResult> {
  const [localFiles, remoteBlobs, manifest] = await Promise.all([
    walkFiles(dir),
    fetchBlobList(server),
    readManifest(dir),
  ]);

  const remoteByKey = new Map(remoteBlobs.map((b) => [b.key, b]));

  const localByKey = new Map<string, LocalEntry>();
  for (const { key, path } of localFiles) {
    const content = await readFile(path);
    const sha256 = createHash("sha256").update(content).digest("hex");
    localByKey.set(key, { path, content, sha256 });
  }

  const uploaded: string[] = [];
  const downloaded: string[] = [];
  const unchanged: string[] = [];
  const newEntries: Record<string, string> = {};

  const allKeys = new Set([...localByKey.keys(), ...remoteByKey.keys()]);

  for (const key of allKeys) {
    const local = localByKey.get(key);
    const remote = remoteByKey.get(key);

    if (local !== undefined && local.sha256 === remote?.sha256) {
      unchanged.push(key);
      newEntries[key] = local.sha256;
      continue;
    }

    const winner = await pickWinner(local, remote, manifest.entries[key]);

    if (winner === "local") {
      // pickWinner only returns "local" when `local` is defined.
      await uploadBlob(server, key, local!.content);
      uploaded.push(key);
      newEntries[key] = local!.sha256;
    } else {
      // ...and only "remote" when `remote` is defined.
      const content = await downloadBlob(server, key);
      await writeLocalFile(dir, key, content);
      downloaded.push(key);
      newEntries[key] = remote!.sha256;
    }
  }

  await writeManifest(dir, { entries: newEntries });

  uploaded.sort();
  downloaded.sort();
  unchanged.sort();

  return { uploaded, downloaded, unchanged };
}

async function pickWinner(
  local: LocalEntry | undefined,
  remote: BlobMeta | undefined,
  baseline: string | undefined,
): Promise<"local" | "remote"> {
  if (local === undefined) {
    return "remote";
  }
  if (remote === undefined) {
    return "local";
  }

  // Both sides have the file and it differs (equal-content case was already
  // handled by the caller). If only one side moved away from the last known
  // common state, that side simply wins outright - no conflict.
  const localChanged = baseline !== local.sha256;
  const remoteChanged = baseline !== remote.sha256;
  if (localChanged && !remoteChanged) {
    return "local";
  }
  if (remoteChanged && !localChanged) {
    return "remote";
  }

  // Both changed since the baseline (or there is no baseline yet for this
  // key), so SHA-256 alone can't pick a winner: fall back to the fixed
  // mtime rule - newer wins, local wins on a tie.
  const localMtime = (await stat(local.path)).mtime.getTime();
  const remoteMtime = Date.parse(remote.modified_at);
  return localMtime >= remoteMtime ? "local" : "remote";
}

async function readManifest(dir: string): Promise<Manifest> {
  try {
    const raw = await readFile(
      join(dir, MANIFEST_DIR_NAME, MANIFEST_FILE_NAME),
      "utf8",
    );
    const parsed: unknown = JSON.parse(raw);
    const entries = (parsed as { entries?: unknown })?.entries;
    if (entries && typeof entries === "object") {
      return { entries: entries as Record<string, string> };
    }
    return { entries: {} };
  } catch {
    return { entries: {} };
  }
}

async function writeManifest(dir: string, manifest: Manifest): Promise<void> {
  const manifestDir = join(dir, MANIFEST_DIR_NAME);
  await mkdir(manifestDir, { recursive: true });
  await writeFile(
    join(manifestDir, MANIFEST_FILE_NAME),
    JSON.stringify(manifest, null, 2),
  );
}

interface LocalFile {
  key: string;
  path: string;
}

async function walkFiles(root: string, dir = root): Promise<LocalFile[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files: LocalFile[] = [];
  for (const entry of entries) {
    if (dir === root && entry.name === MANIFEST_DIR_NAME) {
      continue;
    }
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

function keyToLocalPath(dir: string, key: string): string {
  return join(dir, ...key.split("/"));
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

async function downloadBlob(server: string, key: string): Promise<Buffer> {
  const res = await fetch(`${server}/blobs/${encodeKey(key)}`, {
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`GET /blobs/${key} failed with status ${res.status}`);
  }
  return Buffer.from(await res.arrayBuffer());
}
