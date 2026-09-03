import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, sep } from "node:path";
import {
  downloadBlob,
  fetchBlobList,
  uploadBlob,
  type FileFailure,
  type NetOptions,
} from "./net.js";

/**
 * Bookkeeping file sync keeps at the root of `dir` to remember the last
 * known common (synced) state per key, across separate CLI invocations.
 * Excluded from the local file walk so it's never itself treated as a file
 * to sync.
 */
const MANIFEST_FILENAME = ".syncbox-manifest.json";

export interface SyncResult {
  uploaded: string[];
  downloaded: string[];
  unchanged: string[];
  failed: FileFailure[];
}

type Manifest = Record<string, { sha256: string }>;

interface LocalEntry {
  sha256: string;
  mtimeMs: number;
  content: Buffer;
}

interface RemoteEntry {
  sha256: string;
  modified_at: string;
}

/**
 * Bidirectionally syncs `dir` with the server by key and SHA-256. A file
 * present, or changed, on only one side is transferred to the other
 * (upload/download by content, same as push/pull). A file changed on both
 * sides since the last synced state recorded in `.syncbox-manifest.json` is
 * a conflict: the version with the newer modified_at/mtime wins, ties go to
 * the local version. With no recorded common state (first sync, or a key
 * neither side has seen synced before), a divergence is resolved the same
 * way there being no distinct "one side only" classification to make.
 * Never deletes on either side — a file missing on one side because it was
 * deleted there reappears from the other, since sync only ever transfers
 * content, it doesn't mirror deletions.
 *
 * A key that fails - a local file that can't be read, or a network/server
 * error transferring it - is recorded in `failed` rather than aborting the
 * rest, and is left out of the manifest so it's reconsidered fresh on the
 * next run instead of being wrongly marked resolved.
 */
export async function sync(
  dir: string,
  server: string,
  opts: NetOptions = {},
): Promise<SyncResult> {
  const [manifest, localFiles, remoteBlobs] = await Promise.all([
    readManifest(dir),
    walkFiles(dir),
    fetchBlobList(server, opts),
  ]);

  const failed: FileFailure[] = [];

  const localByKey = new Map<string, LocalEntry>();
  for (const { key, path } of localFiles) {
    try {
      const [content, stats] = await Promise.all([readFile(path), stat(path)]);
      localByKey.set(key, {
        sha256: createHash("sha256").update(content).digest("hex"),
        mtimeMs: stats.mtimeMs,
        content,
      });
    } catch (err) {
      failed.push({ key, message: err instanceof Error ? err.message : String(err) });
    }
  }
  const remoteByKey = new Map<string, RemoteEntry>(
    remoteBlobs.map((b) => [b.key, { sha256: b.sha256, modified_at: b.modified_at }]),
  );

  const uploaded: string[] = [];
  const downloaded: string[] = [];
  const unchanged: string[] = [];
  const newManifest: Manifest = {};

  const allKeys = new Set([...localByKey.keys(), ...remoteByKey.keys()]);
  for (const key of allKeys) {
    try {
      const local = localByKey.get(key);
      const remote = remoteByKey.get(key);

      if (local && !remote) {
        await uploadBlob(server, key, local.content, opts);
        uploaded.push(key);
        newManifest[key] = { sha256: local.sha256 };
        continue;
      }

      if (!local && remote) {
        const content = await downloadBlob(server, key, opts);
        await writeLocalFile(dir, key, content);
        downloaded.push(key);
        newManifest[key] = { sha256: remote.sha256 };
        continue;
      }

      const l = local as LocalEntry;
      const r = remote as RemoteEntry;

      if (l.sha256 === r.sha256) {
        unchanged.push(key);
        newManifest[key] = { sha256: l.sha256 };
        continue;
      }

      const winner = resolveConflict(l, r, manifest[key]?.sha256);

      if (winner === "local") {
        await uploadBlob(server, key, l.content, opts);
        uploaded.push(key);
        newManifest[key] = { sha256: l.sha256 };
      } else {
        const content = await downloadBlob(server, key, opts);
        await writeLocalFile(dir, key, content);
        downloaded.push(key);
        newManifest[key] = { sha256: r.sha256 };
      }
    } catch (err) {
      failed.push({ key, message: err instanceof Error ? err.message : String(err) });
    }
  }

  uploaded.sort();
  downloaded.sort();
  unchanged.sort();
  failed.sort((a, b) => a.key.localeCompare(b.key));

  await writeManifest(dir, newManifest);

  return { uploaded, downloaded, unchanged, failed };
}

/**
 * Decides the winner for a key that differs between local and remote.
 * Changed on only one side relative to `baseSha` (the last synced SHA-256)
 * means that side simply propagates, no timestamp comparison needed. Only
 * a true conflict — changed on both sides, or no recorded base to tell —
 * falls back to the fixed newer-wins/tie-goes-local rule.
 */
function resolveConflict(
  local: LocalEntry,
  remote: RemoteEntry,
  baseSha: string | undefined,
): "local" | "remote" {
  const localChanged = baseSha === undefined || baseSha !== local.sha256;
  const remoteChanged = baseSha === undefined || baseSha !== remote.sha256;

  if (localChanged && !remoteChanged) {
    return "local";
  }
  if (remoteChanged && !localChanged) {
    return "remote";
  }
  return local.mtimeMs >= Date.parse(remote.modified_at) ? "local" : "remote";
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
      const key = toPosixKey(relative(root, fullPath));
      if (key === MANIFEST_FILENAME) {
        continue;
      }
      files.push({ key, path: fullPath });
    }
  }
  return files;
}

function toPosixKey(relativePath: string): string {
  return sep === "/" ? relativePath : relativePath.split(sep).join("/");
}

async function writeLocalFile(
  dir: string,
  key: string,
  content: Buffer,
): Promise<void> {
  const filePath = join(dir, ...key.split("/"));
  await mkdir(dirname(filePath), { recursive: true });
  await writeFile(filePath, content);
}

async function readManifest(dir: string): Promise<Manifest> {
  try {
    const raw = await readFile(join(dir, MANIFEST_FILENAME), "utf8");
    const parsed: unknown = JSON.parse(raw);
    return isManifest(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function isManifest(value: unknown): value is Manifest {
  return typeof value === "object" && value !== null;
}

async function writeManifest(dir: string, manifest: Manifest): Promise<void> {
  await writeFile(
    join(dir, MANIFEST_FILENAME),
    JSON.stringify(manifest, null, 2),
  );
}
