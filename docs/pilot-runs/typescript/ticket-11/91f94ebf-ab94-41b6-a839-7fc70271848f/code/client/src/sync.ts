import * as fs from "node:fs";
import * as path from "node:path";
import { sha256 } from "./hash";
import { downloadBlob, listRemoteBlobs, uploadBlob } from "./httpClient";
import { walkFiles } from "./walk";

export interface SyncResult {
  uploaded: string[];
  downloaded: string[];
  unchanged: string[];
  failed: { key: string; error: string }[];
}

// Manifest lives inside <dir> because that's the only thing that persists
// between separate `run-client sync` invocations (each is a fresh
// container with just <dir> mounted). It's excluded from the set of keys
// being synced so it never gets pushed/pulled as if it were user content.
const MANIFEST_RELATIVE_PATH = [".syncbox", "manifest.json"];
const MANIFEST_KEY = MANIFEST_RELATIVE_PATH.join("/");

// key -> sha256 of the content last known to be identical on both sides.
type Manifest = Record<string, string>;

function manifestPath(dir: string): string {
  return path.join(dir, ...MANIFEST_RELATIVE_PATH);
}

function loadManifest(dir: string): Manifest {
  try {
    return JSON.parse(fs.readFileSync(manifestPath(dir), "utf8")) as Manifest;
  } catch {
    return {};
  }
}

function saveManifest(dir: string, manifest: Manifest): void {
  const p = manifestPath(dir);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(manifest, null, 2));
}

function localPath(dir: string, key: string): string {
  return path.join(dir, ...key.split("/"));
}

/**
 * Bidirectionally syncs <dir> with the server: a key present on only one
 * side is copied to the other; a key that diverges on both sides is
 * resolved per SYNCBOX-SPEC.md's "Правило разрешения конфликтов для
 * sync" using a manifest of the last known common SHA-256 per key,
 * persisted under <dir>/.syncbox/manifest.json. Never deletes a file on
 * either side — a key missing on one side is treated as "not yet copied
 * there", not as a deletion to propagate.
 */
export async function sync(dir: string, server: string): Promise<SyncResult> {
  const manifest = loadManifest(dir);

  const remote = await listRemoteBlobs(server);
  const remoteByKey = new Map(
    remote.filter((blob) => blob.key !== MANIFEST_KEY).map((blob) => [blob.key, blob])
  );

  const localKeys = walkFiles(dir).filter((key) => key !== MANIFEST_KEY);
  const localHashes = new Map<string, string>();
  const failed: { key: string; error: string }[] = [];
  const unreadableKeys = new Set<string>();
  for (const key of localKeys) {
    try {
      localHashes.set(key, sha256(fs.readFileSync(localPath(dir, key))));
    } catch (err) {
      unreadableKeys.add(key);
      failed.push({
        key,
        error: `could not read local file: ${(err as Error).message}`,
      });
    }
  }

  // A key whose local copy couldn't be read is left untouched on both
  // sides rather than treated as "server-only" (which would silently
  // overwrite it) or "local-only" (nothing to upload anyway).
  const allKeys = new Set(
    [...localHashes.keys(), ...remoteByKey.keys()].filter(
      (key) => !unreadableKeys.has(key)
    )
  );

  const uploaded: string[] = [];
  const downloaded: string[] = [];
  const unchanged: string[] = [];
  const nextManifest: Manifest = { ...manifest };

  for (const key of [...allKeys].sort()) {
    const localHash = localHashes.get(key);
    const remoteBlob = remoteByKey.get(key);
    const remoteHash = remoteBlob?.sha256;
    const absPath = localPath(dir, key);

    try {
      if (remoteHash === undefined) {
        // local-only: push it.
        await uploadBlob(server, key, fs.readFileSync(absPath));
        uploaded.push(key);
        nextManifest[key] = localHash!;
        continue;
      }

      if (localHash === undefined) {
        // server-only: pull it.
        const content = await downloadBlob(server, key);
        fs.mkdirSync(path.dirname(absPath), { recursive: true });
        fs.writeFileSync(absPath, content);
        downloaded.push(key);
        nextManifest[key] = remoteHash;
        continue;
      }

      if (localHash === remoteHash) {
        unchanged.push(key);
        nextManifest[key] = localHash;
        continue;
      }

      // Both sides have the key with different content. Figure out which
      // side actually changed relative to the last known common state.
      const baseline = manifest[key];
      const onlyLocalChanged = baseline !== undefined && baseline === remoteHash;
      const onlyRemoteChanged = baseline !== undefined && baseline === localHash;

      // Genuine conflict: both sides changed since the baseline, or there
      // is no baseline at all (e.g. first ever sync run for this key) so
      // it's impossible to tell which side "changed" — fall back to the
      // same fixed newer-wins/tie-goes-to-local rule in both cases.
      const isConflict = !onlyLocalChanged && !onlyRemoteChanged;

      let localWins: boolean;
      if (isConflict) {
        const localMtimeMs = fs.statSync(absPath).mtimeMs;
        const remoteMtimeMs = new Date(remoteBlob!.modified_at).getTime();
        localWins = localMtimeMs >= remoteMtimeMs;
      } else {
        localWins = onlyLocalChanged;
      }

      if (localWins) {
        await uploadBlob(server, key, fs.readFileSync(absPath));
        uploaded.push(key);
        nextManifest[key] = localHash;
      } else {
        const content = await downloadBlob(server, key);
        fs.writeFileSync(absPath, content);
        downloaded.push(key);
        nextManifest[key] = remoteHash;
      }
    } catch (err) {
      failed.push({ key, error: (err as Error).message });
    }
  }

  saveManifest(dir, nextManifest);

  return { uploaded, downloaded, unchanged, failed };
}
