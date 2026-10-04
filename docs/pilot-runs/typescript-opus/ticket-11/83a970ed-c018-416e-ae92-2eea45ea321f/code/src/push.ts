import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";

import { decodeUtf8 } from "./blobs.js";
import { ClientError, type RemoteBlob, type SyncboxClient } from "./client.js";
import { byKey, failure, transferEach, type Failure } from "./failures.js";

export interface LocalFile {
  /** Relative POSIX path inside the scanned directory: the blob key. */
  key: string;
  path: string;
  size: number;
}

export interface Reporter {
  info(line: string): void;
  warn(line: string): void;
}

export interface PushSummary {
  uploaded: string[];
  unchanged: string[];
  /** Directory entries that can't be pushed (links, special files, bad names). */
  skipped: number;
  /** Files that couldn't be compared or uploaded, sorted by key. */
  failed: Failure[];
  /** Files not even tried because the server had become unreachable. */
  notAttempted: number;
}

/** What push would do: worked out without changing anything. */
export interface PushPlan {
  /** Files the server doesn't have, or has with a different SHA-256. */
  upload: LocalFile[];
  unchanged: string[];
  skipped: number;
  /** Files and directories that couldn't be read. */
  failed: Failure[];
}

/**
 * Uploads every file under `dir` that the server doesn't have or has with a
 * different SHA-256; files the server already has with the same content are
 * left alone. Nothing on the server is deleted. A file that can't be read or
 * uploaded doesn't stop the others: it ends up in the summary's `failed`.
 */
export async function push(dir: string, client: SyncboxClient, reporter: Reporter): Promise<PushSummary> {
  await assertDirectory(dir);
  // Ask the server first: if it is unreachable, there's no point in hashing.
  const plan = await planPush(dir, await client.list(), reporter);

  const uploaded: string[] = [];
  const { failed, notAttempted } = await transferEach(
    plan.upload,
    (file) => file.key,
    async (file) => {
      await client.put(file.key, createReadStream(file.path));
      uploaded.push(file.key);
      reporter.info(`uploaded ${file.key}`);
    },
  );
  return {
    uploaded,
    unchanged: plan.unchanged,
    skipped: plan.skipped,
    failed: [...plan.failed, ...failed].sort(byKey),
    notAttempted,
  };
}

/**
 * Compares the files under `dir` with the server's list, sorted by key.
 * Only reads `dir`. `hash` lets a caller that compares the same files more
 * than once hash each of them only once.
 */
export async function planPush(
  dir: string,
  remoteList: readonly RemoteBlob[],
  reporter: Reporter,
  hash: (file: LocalFile) => Promise<string> = hashFile,
): Promise<PushPlan> {
  const remote = new Map(remoteList.map((blob) => [blob.key, blob]));
  const { files, skipped, failed } = await scanDir(dir, reporter);

  const plan: PushPlan = { upload: [], unchanged: [], skipped, failed };
  for (const file of files) {
    const existing = remote.get(file.key);
    // A different size already means different content: no need to hash.
    if (existing === undefined || existing.size !== file.size) {
      plan.upload.push(file);
      continue;
    }
    let digest;
    try {
      digest = await hash(file);
    } catch (err) {
      plan.failed.push(failure(file.key, err));
      continue;
    }
    if (digest === existing.sha256) {
      plan.unchanged.push(file.key);
    } else {
      plan.upload.push(file);
    }
  }
  return plan;
}

export async function assertDirectory(dir: string): Promise<void> {
  let st;
  try {
    st = await stat(dir);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") throw new ClientError(`${dir}: no such directory`);
    throw new ClientError(`${dir}: ${(err as Error).message}`);
  }
  if (!st.isDirectory()) throw new ClientError(`${dir}: not a directory`);
}

/**
 * Lists the regular files under `root` recursively, sorted by key. Symbolic
 * links and special files are skipped with a warning, and so are names that
 * aren't valid UTF-8, since no key can represent them. Empty directories
 * have no blob counterpart and simply produce nothing. A subdirectory or
 * file that can't be read is left out and reported in `failed`; only
 * failing to read `root` itself is an error.
 */
export async function scanDir(
  root: string,
  reporter: Reporter,
): Promise<{ files: LocalFile[]; skipped: number; failed: Failure[] }> {
  const files: LocalFile[] = [];
  const failed: Failure[] = [];
  let skipped = 0;

  const walk = async (dir: string, prefix: string): Promise<void> => {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true, encoding: "buffer" });
    } catch (err) {
      const message = `cannot read directory ${prefix === "" ? "." : prefix.slice(0, -1)}: ${(err as Error).message}`;
      if (prefix === "") throw new ClientError(message);
      failed.push({ key: prefix, message });
      return;
    }
    for (const entry of entries) {
      const name = decodeUtf8(entry.name);
      if (name === undefined) {
        reporter.warn(`skipping ${prefix}${entry.name.toString("utf8")}: name is not valid UTF-8`);
        skipped++;
        continue;
      }
      const key = prefix + name;
      const path = join(dir, name);
      if (entry.isDirectory()) {
        await walk(path, `${key}/`);
      } else if (entry.isFile()) {
        let st;
        try {
          st = await stat(path);
        } catch (err) {
          failed.push({ key, message: `cannot read ${key}: ${(err as Error).message}` });
          continue;
        }
        files.push({ key, path, size: st.size });
      } else {
        reporter.warn(`skipping ${key}: ${entry.isSymbolicLink() ? "symbolic link" : "not a regular file"}`);
        skipped++;
      }
    }
  };

  await walk(root, "");
  files.sort(byKey);
  return { files, skipped, failed: failed.sort(byKey) };
}

export async function hashFile(file: LocalFile): Promise<string> {
  const hash = createHash("sha256");
  try {
    for await (const chunk of createReadStream(file.path)) {
      hash.update(chunk as Buffer);
    }
  } catch (err) {
    throw new ClientError(`cannot read ${file.key}: ${(err as Error).message}`);
  }
  return hash.digest("hex");
}
