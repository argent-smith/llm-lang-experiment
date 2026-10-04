import { createReadStream } from "node:fs";
import { realpath, stat } from "node:fs/promises";

import { ClientError, type RemoteBlob, type SyncboxClient } from "./client.js";
import { download } from "./pull.js";
import { assertDirectory, type LocalFile, type Reporter } from "./push.js";
import { SyncState, type SyncBase } from "./state.js";
import { compare } from "./status.js";

export interface SyncOptions {
  /** Directory the state of synced directories is kept in (see defaultStateDir). */
  stateDir: string;
  /** Identifies `dir` in the state; by default its real absolute path. */
  dirId?: string | undefined;
}

/**
 * A file that differs on the two sides with neither of them known to be
 * unchanged since the last sync, settled by modification time.
 */
export interface Conflict {
  key: string;
  winner: "local" | "server";
  /** The winner is newer, or both are equally new and the local one wins. */
  why: "newer" | "same-time";
  /** Whether a previous sync left a common version (otherwise this is the first time it is compared). */
  hadBase: boolean;
}

export interface SyncSummary {
  /** Sorted by key, as are the other lists. */
  uploaded: string[];
  downloaded: string[];
  unchanged: string[];
  /** Transfers among the above that were settled by modification time. */
  conflicts: Conflict[];
  /** Entries left out on either side (links, special files, bad names). */
  skipped: number;
}

type Action =
  | { kind: "upload"; key: string; file: LocalFile; conflict: Conflict | undefined }
  | { kind: "download"; key: string; blob: RemoteBlob; target: string; conflict: Conflict | undefined };

/**
 * Brings `dir` and the server to the same content, in both directions, by
 * key and SHA-256. A file only one side has is copied to the other. A file
 * that differs goes in the direction of the side that changed it since the
 * last sync; if both did (or there was no sync yet to tell), the version
 * with the later modification time (local mtime, server modified_at) wins,
 * and the local one when they are equal. Nothing is deleted on either side.
 *
 * What both sides had in common after a sync is kept in a state file outside
 * `dir`, updated with every file transferred — also when the sync fails
 * halfway. Stops at the first failure, and fails before transferring
 * anything if some blob can't be written locally.
 */
export async function sync(dir: string, client: SyncboxClient, reporter: Reporter, options: SyncOptions): Promise<SyncSummary> {
  await assertDirectory(dir);
  const state = new SyncState(options.stateDir, client.server, options.dirId ?? (await realpath(dir)));
  const base = await state.load(reporter);

  const remote = await client.list();
  const comparison = await compare(dir, remote, reporter);
  const blocked = comparison.pull.blocked[0];
  if (blocked !== undefined) {
    throw new ClientError(`cannot write ${blocked.key}: ${blocked.reason}`);
  }

  const remoteByKey = new Map(remote.map((blob) => [blob.key, blob]));
  const localKeys = new Set([...comparison.push.upload.map((file) => file.key), ...comparison.push.unchanged]);

  const actions: Action[] = [];
  for (const file of comparison.push.upload) {
    const blob = remoteByKey.get(file.key);
    actions.push(
      blob === undefined
        ? { kind: "upload", key: file.key, file, conflict: undefined }
        : await settle(file, blob, base.get(file.key), await comparison.hash(file)),
    );
  }
  for (const { blob, target } of comparison.pull.download) {
    if (!localKeys.has(blob.key)) {
      actions.push({ kind: "download", key: blob.key, blob, target, conflict: undefined });
    }
  }
  actions.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

  // The next base: what both sides have in common once this sync is done.
  const next: SyncBase = new Map(base);
  for (const key of next.keys()) {
    if (!localKeys.has(key) && !remoteByKey.has(key)) next.delete(key);
  }
  for (const key of comparison.push.unchanged) {
    next.set(key, remoteByKey.get(key)!.sha256);
  }

  const summary: SyncSummary = {
    uploaded: [],
    downloaded: [],
    unchanged: comparison.push.unchanged,
    conflicts: [],
    skipped: comparison.warnings.size,
  };
  try {
    for (const action of actions) {
      if (action.kind === "upload") {
        next.set(action.key, await client.put(action.key, createReadStream(action.file.path)));
        summary.uploaded.push(action.key);
      } else {
        await download(client, action.blob, action.target);
        next.set(action.key, action.blob.sha256);
        summary.downloaded.push(action.key);
      }
      if (action.conflict !== undefined) summary.conflicts.push(action.conflict);
      reporter.info(describe(action));
    }
  } catch (err) {
    // Keep what did get transferred; the original failure is what matters.
    await state.save(next).catch(() => {});
    throw err;
  }
  await state.save(next);
  return summary;
}

/**
 * Decides which way a file that differs goes: from the side that changed it
 * since the last sync, or, if both did or that isn't known, by the conflict
 * rule — the later modification time wins, the local version on a tie.
 */
async function settle(file: LocalFile, blob: RemoteBlob, known: string | undefined, local: string): Promise<Action> {
  const upload = (conflict?: Conflict): Action => ({ kind: "upload", key: file.key, file, conflict });
  const downloadIt = (conflict?: Conflict): Action => ({ kind: "download", key: file.key, blob, target: file.path, conflict });
  if (known === local) return downloadIt();
  if (known === blob.sha256) return upload();

  const serverMs = Date.parse(blob.modified_at);
  if (Number.isNaN(serverMs)) {
    throw new ClientError(`GET /blobs: server listed an invalid modified_at for ${file.key}: ${JSON.stringify(blob.modified_at)}`);
  }
  let localMs;
  try {
    localMs = roundedMs((await stat(file.path, { bigint: true })).mtimeNs);
  } catch (err) {
    throw new ClientError(`cannot read ${file.key}: ${(err as Error).message}`);
  }
  const hadBase = known !== undefined;
  if (serverMs > localMs) return downloadIt({ key: file.key, winner: "server", why: "newer", hadBase });
  return upload({ key: file.key, winner: "local", why: serverMs === localMs ? "same-time" : "newer", hadBase });
}

const NS_PER_MS = 1_000_000n;

/**
 * A file time in whole milliseconds, rounded to the nearest one the way the
 * server rounds modified_at, so that equal times compare equal.
 */
function roundedMs(ns: bigint): number {
  const shifted = ns + NS_PER_MS / 2n;
  return Number(shifted / NS_PER_MS - (shifted % NS_PER_MS < 0n ? 1n : 0n));
}

function describe(action: Action): string {
  const line = `${action.kind === "upload" ? "uploaded" : "downloaded"} ${action.key}`;
  const conflict = action.conflict;
  if (conflict === undefined) return line;
  const situation = conflict.hadBase ? "changed on both sides" : "differs, no previous sync";
  const verdict =
    conflict.why === "same-time" ? "same modification time, local version kept" : `${conflict.winner} version is newer`;
  return `${line}  (${situation}: ${verdict})`;
}

/** The summary line printed by `syncbox sync`. */
export function formatSyncSummary(summary: SyncSummary): string {
  const conflicts = summary.conflicts.length > 0 ? `, ${summary.conflicts.length} settled by modification time` : "";
  const skipped = summary.skipped > 0 ? `, ${summary.skipped} skipped` : "";
  return `sync: ${summary.uploaded.length} uploaded, ${summary.downloaded.length} downloaded, ${summary.unchanged.length} unchanged${conflicts}${skipped}`;
}
