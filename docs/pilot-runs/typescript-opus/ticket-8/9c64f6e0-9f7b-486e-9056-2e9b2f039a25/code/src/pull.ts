import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, open, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";

import { ClientError, type RemoteBlob, type SyncboxClient } from "./client.js";
import { assertDirectory, hashFile, type LocalFile, type Reporter } from "./push.js";

export interface PullSummary {
  downloaded: string[];
  unchanged: string[];
  /** Blobs that can't be pulled (unusable keys, links or special files in the way). */
  skipped: number;
}

/** What is at a key's path in the local directory. */
type LocalEntry = { kind: "missing" } | ({ kind: "file" } & LocalFile) | { kind: "skip"; reason: string };

/**
 * Downloads every blob the server has that is missing under `dir` or differs
 * from the local file by SHA-256, creating subdirectories as needed; files
 * that already have the server's content are left alone. Nothing local is
 * deleted. Each file is written to a temporary file next to it and renamed
 * into place, so it is never left half-written. Stops at the first failure.
 */
export async function pull(dir: string, client: SyncboxClient, reporter: Reporter): Promise<PullSummary> {
  await assertDirectory(dir);
  const remote = (await client.list()).sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

  const summary: PullSummary = { downloaded: [], unchanged: [], skipped: 0 };
  for (const blob of remote) {
    const segments = keySegments(blob.key);
    if (segments === undefined) {
      reporter.warn(`skipping ${JSON.stringify(blob.key)}: not a relative path inside the directory`);
      summary.skipped++;
      continue;
    }
    const local = await inspect(dir, blob.key, segments);
    if (local.kind === "skip") {
      reporter.warn(`skipping ${blob.key}: ${local.reason}`);
      summary.skipped++;
      continue;
    }
    // A different size already means different content: no need to hash.
    if (local.kind === "file" && local.size === blob.size && (await hashFile(local)) === blob.sha256) {
      summary.unchanged.push(blob.key);
      continue;
    }
    await download(client, blob, join(dir, ...segments));
    summary.downloaded.push(blob.key);
    reporter.info(`downloaded ${blob.key}`);
  }
  return summary;
}

/**
 * Splits a key from the server's list into path segments, or returns
 * undefined if it isn't a relative POSIX path that stays inside the
 * directory. The server refuses to store such keys; this doesn't rely on it.
 */
function keySegments(key: string): string[] | undefined {
  if (key === "" || key.startsWith("/") || key.includes("\0")) return undefined;
  // Lone surrogates would end up as U+FFFD in the file name: another key.
  if (Buffer.from(key, "utf8").toString("utf8") !== key) return undefined;
  const segments = key.split("/");
  if (segments.some((s) => s === "" || s === "." || s === "..")) return undefined;
  return segments;
}

/**
 * Looks at what is at the key's path, without following symbolic links: a
 * link (to a file or along the way) is skipped rather than written through
 * or replaced, just as push skips links. So are special files. A directory
 * where the file belongs, or a file where a directory belongs, is an error.
 */
async function inspect(dir: string, key: string, segments: string[]): Promise<LocalEntry> {
  let path = dir;
  for (const [i, segment] of segments.entries()) {
    path = join(path, segment);
    const sub = segments.slice(0, i + 1).join("/");
    const last = i === segments.length - 1;
    let st;
    try {
      st = await lstat(path);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return { kind: "missing" };
      throw new ClientError(`cannot read ${sub}: ${(err as Error).message}`);
    }
    if (st.isSymbolicLink()) {
      return { kind: "skip", reason: last ? "symbolic link" : `${sub} is a symbolic link` };
    }
    if (!last) {
      if (!st.isDirectory()) throw new ClientError(`cannot write ${key}: ${sub} is not a directory`);
    } else if (st.isDirectory()) {
      throw new ClientError(`cannot write ${key}: it is a directory`);
    } else if (!st.isFile()) {
      return { kind: "skip", reason: "not a regular file" };
    } else {
      return { kind: "file", key, path, size: st.size };
    }
  }
  return { kind: "missing" };
}

/**
 * Streams the blob into a temporary file in the target's directory and,
 * once it is complete, flushed and has the SHA-256 the server listed,
 * renames it over the target. The temporary file is removed on failure.
 */
async function download(client: SyncboxClient, blob: RemoteBlob, target: string): Promise<void> {
  const writing = <T>(op: Promise<T>): Promise<T> =>
    op.catch((err: unknown) => {
      throw new ClientError(`cannot write ${blob.key}: ${(err as Error).message}`);
    });

  const tmp = join(dirname(target), `.syncbox-${randomUUID()}.tmp`);
  await writing(mkdir(dirname(target), { recursive: true }));
  const handle = await writing(open(tmp, "wx"));
  try {
    const hash = createHash("sha256");
    try {
      for await (const chunk of await client.get(blob.key)) {
        hash.update(chunk);
        for (let offset = 0; offset < chunk.length; ) {
          offset += (await writing(handle.write(chunk, offset))).bytesWritten;
        }
      }
      // Otherwise a crash shortly after the rename could leave the file
      // without its data.
      await writing(handle.datasync());
    } finally {
      await writing(handle.close());
    }
    if (hash.digest("hex") !== blob.sha256) {
      throw new ClientError(`GET ${blob.key}: received content does not match the SHA-256 the server listed (changed on the server meanwhile?)`);
    }
    await writing(rename(tmp, target));
  } catch (err) {
    await rm(tmp, { force: true });
    throw err;
  }
}
