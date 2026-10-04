import { type RemoteBlob, type SyncboxClient } from "./client.js";
import { byKey, failureCounts, type Failure } from "./failures.js";
import { planPull, type PullPlan } from "./pull.js";
import { assertDirectory, hashFile, planPush, type LocalFile, type PushPlan, type Reporter } from "./push.js";

/** Why a file would be transferred: the other side doesn't have it, or has other content. */
export type Difference = "missing" | "differs";

export interface Transfer {
  key: string;
  why: Difference;
}

export interface StatusReport {
  /** What push would upload, sorted by key. */
  upload: Transfer[];
  /** What pull would download, sorted by key. */
  download: Transfer[];
  /** Files with the same SHA-256 on both sides. */
  unchanged: string[];
  /** Entries left out on either side (links, special files, bad names, blobs pull can't write). */
  skipped: number;
  /** Local files and directories that couldn't be read to compare them, sorted by key. */
  failed: Failure[];
}

/**
 * Compares `dir` with the server's list by key and SHA-256 and reports what
 * push and pull would transfer, without transferring anything: the only
 * request is GET /blobs, and `dir` is only read. A file that differs is in
 * both lists, since push would upload it and pull would download it.
 */
export async function status(dir: string, client: SyncboxClient, reporter: Reporter): Promise<StatusReport> {
  await assertDirectory(dir);
  const remote = await client.list();
  const { push: pushPlan, pull: pullPlan, warn, warnings, failed } = await compare(dir, remote, reporter);
  for (const { key, reason } of pullPlan.blocked) {
    warn.warn(`skipping ${key}: pull could not write it: ${reason}`);
  }

  const remoteKeys = new Set(remote.map((blob) => blob.key));
  const localKeys = new Set([...pushPlan.upload.map((file) => file.key), ...pushPlan.unchanged]);
  return {
    upload: pushPlan.upload.map(({ key }) => ({ key, why: remoteKeys.has(key) ? "differs" : "missing" })),
    download: pullPlan.download.map(({ blob: { key } }) => ({ key, why: localKeys.has(key) ? "differs" : "missing" })),
    unchanged: pushPlan.unchanged,
    skipped: warnings.size,
    failed,
  };
}

/** Both directions of a comparison between a directory and the server's list. */
export interface Comparison {
  push: PushPlan;
  pull: PullPlan;
  /** SHA-256 of a local file, hashed at most once per comparison. */
  hash: (file: LocalFile) => Promise<string>;
  /** Passes each distinct warning on to the caller's reporter, once. */
  warn: Reporter;
  /** The warnings passed on so far: one per entry skipped on either side. */
  warnings: Set<string>;
  /** What either plan couldn't read locally, once per key, sorted by key. */
  failed: Failure[];
}

/**
 * Plans push and pull against the same server list; only reads `dir`. Both
 * plans look at the same files: each is hashed once, and a problem both
 * directions run into is reported once.
 */
export async function compare(dir: string, remote: readonly RemoteBlob[], reporter: Reporter): Promise<Comparison> {
  const hashes = new Map<string, Promise<string>>();
  const hash = (file: LocalFile): Promise<string> => {
    let digest = hashes.get(file.key);
    if (digest === undefined) {
      digest = hashFile(file);
      hashes.set(file.key, digest);
    }
    return digest;
  };
  const warnings = new Set<string>();
  const warn: Reporter = {
    info: (line) => reporter.info(line),
    warn: (line) => {
      if (warnings.has(line)) return;
      warnings.add(line);
      reporter.warn(line);
    },
  };

  const push = await planPush(dir, remote, warn, hash);
  const pull = await planPull(dir, remote, warn, hash);
  const failed = new Map<string, Failure>();
  for (const f of [...push.failed, ...pull.failed]) {
    if (!failed.has(f.key)) failed.set(f.key, f);
  }
  return { push, pull, hash, warn, warnings, failed: [...failed.values()].sort(byKey) };
}

/** The report as printed by `syncbox status`: one line per transfer, then a summary. */
export function formatStatus(report: StatusReport): string[] {
  const lines = [
    ...report.upload.map(({ key, why }) => `upload    ${key}  (${why === "missing" ? "not on the server" : "differs"})`),
    ...report.download.map(({ key, why }) => `download  ${key}  (${why === "missing" ? "not in the directory" : "differs"})`),
  ];
  const skipped = report.skipped > 0 ? `, ${report.skipped} skipped` : "";
  const failed = failureCounts({ failed: report.failed, notAttempted: 0 });
  if (report.upload.length === 0 && report.download.length === 0 && report.failed.length === 0) {
    lines.push(`status: in sync, nothing to upload or download (${report.unchanged.length} unchanged${skipped})`);
  } else {
    lines.push(
      `status: ${report.upload.length} to upload, ${report.download.length} to download, ${report.unchanged.length} unchanged${skipped}${failed}`,
    );
  }
  return lines;
}
