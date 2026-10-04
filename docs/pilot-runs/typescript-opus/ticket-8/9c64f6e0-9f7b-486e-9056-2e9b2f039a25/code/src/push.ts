import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";

import { decodeUtf8 } from "./blobs.js";
import { ClientError, type SyncboxClient } from "./client.js";

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
}

/**
 * Uploads every file under `dir` that the server doesn't have or has with a
 * different SHA-256; files the server already has with the same content are
 * left alone. Nothing on the server is deleted. Stops at the first failure.
 */
export async function push(dir: string, client: SyncboxClient, reporter: Reporter): Promise<PushSummary> {
  await assertDirectory(dir);
  // Ask the server first: if it is unreachable, there's no point in hashing.
  const remote = new Map((await client.list()).map((blob) => [blob.key, blob]));
  const { files, skipped } = await scanDir(dir, reporter);

  const summary: PushSummary = { uploaded: [], unchanged: [], skipped };
  for (const file of files) {
    const existing = remote.get(file.key);
    // A different size already means different content: no need to hash.
    if (existing !== undefined && existing.size === file.size && (await hashFile(file)) === existing.sha256) {
      summary.unchanged.push(file.key);
      continue;
    }
    await client.put(file.key, createReadStream(file.path));
    summary.uploaded.push(file.key);
    reporter.info(`uploaded ${file.key}`);
  }
  return summary;
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
 * have no blob counterpart and simply produce nothing.
 */
export async function scanDir(root: string, reporter: Reporter): Promise<{ files: LocalFile[]; skipped: number }> {
  const files: LocalFile[] = [];
  let skipped = 0;

  const walk = async (dir: string, prefix: string): Promise<void> => {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true, encoding: "buffer" });
    } catch (err) {
      throw new ClientError(`cannot read directory ${prefix === "" ? "." : prefix}: ${(err as Error).message}`);
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
          throw new ClientError(`cannot read ${key}: ${(err as Error).message}`);
        }
        files.push({ key, path, size: st.size });
      } else {
        reporter.warn(`skipping ${key}: ${entry.isSymbolicLink() ? "symbolic link" : "not a regular file"}`);
        skipped++;
      }
    }
  };

  await walk(root, "");
  files.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return { files, skipped };
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
