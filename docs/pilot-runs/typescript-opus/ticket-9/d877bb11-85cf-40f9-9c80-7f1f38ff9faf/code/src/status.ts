import { type SyncboxClient } from "./client.js";
import { planPull } from "./pull.js";
import { assertDirectory, hashFile, planPush, type LocalFile, type Reporter } from "./push.js";

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

  // Both comparisons look at the same files: hash each once, warn about each once.
  const hashes = new Map<string, Promise<string>>();
  const hash = (file: LocalFile): Promise<string> => {
    let digest = hashes.get(file.key);
    if (digest === undefined) {
      digest = hashFile(file);
      hashes.set(file.key, digest);
    }
    return digest;
  };
  const warned = new Set<string>();
  const once: Reporter = {
    info: (line) => reporter.info(line),
    warn: (line) => {
      if (warned.has(line)) return;
      warned.add(line);
      reporter.warn(line);
    },
  };

  const pushPlan = await planPush(dir, remote, once, hash);
  const pullPlan = await planPull(dir, remote, once, hash);
  for (const { key, reason } of pullPlan.blocked) {
    once.warn(`skipping ${key}: pull could not write it: ${reason}`);
  }

  const remoteKeys = new Set(remote.map((blob) => blob.key));
  const localKeys = new Set([...pushPlan.upload.map((file) => file.key), ...pushPlan.unchanged]);
  return {
    upload: pushPlan.upload.map(({ key }) => ({ key, why: remoteKeys.has(key) ? "differs" : "missing" })),
    download: pullPlan.download.map(({ blob: { key } }) => ({ key, why: localKeys.has(key) ? "differs" : "missing" })),
    unchanged: pushPlan.unchanged,
    skipped: warned.size,
  };
}

/** The report as printed by `syncbox status`: one line per transfer, then a summary. */
export function formatStatus(report: StatusReport): string[] {
  const lines = [
    ...report.upload.map(({ key, why }) => `upload    ${key}  (${why === "missing" ? "not on the server" : "differs"})`),
    ...report.download.map(({ key, why }) => `download  ${key}  (${why === "missing" ? "not in the directory" : "differs"})`),
  ];
  const skipped = report.skipped > 0 ? `, ${report.skipped} skipped` : "";
  if (report.upload.length === 0 && report.download.length === 0) {
    lines.push(`status: in sync, nothing to upload or download (${report.unchanged.length} unchanged${skipped})`);
  } else {
    lines.push(
      `status: ${report.upload.length} to upload, ${report.download.length} to download, ${report.unchanged.length} unchanged${skipped}`,
    );
  }
  return lines;
}
