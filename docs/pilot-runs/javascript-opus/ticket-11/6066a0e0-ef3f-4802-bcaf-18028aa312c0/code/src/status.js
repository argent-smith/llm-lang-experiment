import { Failures, LocalConflictError, failureCounts, printable } from './failures.js';
import { listFiles, keySegments, sha256File } from './local-files.js';
import { inspectTarget } from './pull.js';

/**
 * Works out what push and pull would transfer between `dir` and the server,
 * changing nothing on either side: the only requests are GET /blobs, and the
 * directory is only read.
 *
 * `upload` is what push would send: local files the server lacks ("new") or
 * holds with a different SHA-256 ("differs"). `download` is what pull would
 * fetch: blobs `dir` lacks or holds with different contents. A file that
 * differs is therefore in both lists; which side wins is up to sync.
 *
 * Files push would not read (symbolic links, special files, names that are
 * not valid UTF-8) and blobs pull would not write (keys that are not plain
 * relative paths, paths through a symbolic link, something else in the way)
 * are reported through `warn` and left out.
 *
 * A local file or directory that cannot be read is recorded in `failed` and
 * left out of both lists, as is every blob under such a directory; the rest
 * is still compared.
 *
 * @param {{
 *   dir: string,
 *   client: import('./client.js').SyncboxClient,
 *   warn?: (line: string) => void,  files and blobs left out
 * }} options
 * @returns {Promise<{
 *   upload: Array<{ key: string, reason: 'new' | 'differs' }>,
 *   download: Array<{ key: string, reason: 'new' | 'differs' }>,
 *   upToDate: string[],
 *   failed: Array<{ key: string, reason: string, error: Error }>,
 * }>} sorted by key
 * @throws {import('./client.js').RequestError} if the server's list cannot be had
 */
export async function status({ dir, client, warn = () => {} }) {
  const failures = new Failures();
  const unreadableDirs = [];
  const files = await listFiles(dir, {
    onSkip: (relPath, reason) => warn(`skipping ${relPath}: ${reason}`),
    onError: (relPath, err) => {
      unreadableDirs.push(relPath);
      failures.add(`${relPath}/`, err);
    },
  });
  const blobs = (await client.list()).sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  const remote = new Map(blobs.map((blob) => [blob.key, blob.sha256]));

  const local = new Map();
  const unreadable = new Set();
  const upload = [];
  const upToDate = [];
  await failures.each(files, undefined, async ({ key, path }) => {
    let sha256;
    try {
      sha256 = await sha256File(path);
    } catch (err) {
      unreadable.add(key);
      throw err;
    }
    local.set(key, sha256);
    if (!remote.has(key)) {
      upload.push({ key, reason: 'new' });
    } else if (remote.get(key) !== sha256) {
      upload.push({ key, reason: 'differs' });
    } else {
      upToDate.push(key);
    }
  });

  // The same checks pull makes before writing anything. What could not be
  // read locally cannot be compared: it has failed already.
  const download = [];
  const comparable = blobs.filter(
    (blob) => !unreadable.has(blob.key) && !unreadableDirs.some((d) => blob.key.startsWith(`${d}/`)),
  );
  await failures.each(comparable, undefined, async (blob) => {
    if (local.get(blob.key) === blob.sha256) {
      return;
    }
    const segments = keySegments(blob.key);
    if (segments === null) {
      warn(`skipping ${JSON.stringify(blob.key)}: key is not a relative path inside the directory`);
      return;
    }
    let target;
    try {
      target = await inspectTarget(dir, blob.key, segments);
    } catch (err) {
      if (err instanceof LocalConflictError) {
        warn(`${err.message} (pull would fail here)`);
        return;
      }
      throw err;
    }
    if (target.skip !== undefined) {
      warn(`skipping ${blob.key}: ${target.skip}`);
      return;
    }
    if (target.mode === undefined) {
      download.push({ key: blob.key, reason: 'new' });
    } else if ((local.get(blob.key) ?? (await sha256File(target.path))) !== blob.sha256) {
      download.push({ key: blob.key, reason: 'differs' });
    }
  });

  return { upload, download, upToDate, ...failures.result() };
}

/**
 * The report the status command prints.
 *
 * @param {Awaited<ReturnType<typeof status>>} result
 * @returns {string[]} lines
 */
export function formatStatus({ upload, download, upToDate, failed = [] }) {
  const lines = [];
  // Not "up to date" if some files could not be compared.
  if (upload.length === 0 && download.length === 0 && failed.length === 0) {
    lines.push('Up to date: nothing to upload or download.');
  } else {
    section(lines, 'Would upload to the server (push)', upload);
    section(lines, 'Would download from the server (pull)', download);
    const both = upload.filter((f) => f.reason === 'differs').length;
    if (both > 0) {
      lines.push(
        `${files(both)} ${both === 1 ? 'differs' : 'differ'} on both sides: ` +
          "push would replace the server's copy, pull the local one.",
      );
    }
  }
  lines.push(`status: ${upload.length} to upload, ${download.length} to download, ${upToDate.length} up to date${failureCounts({ failed })}`);
  return lines;
}

function section(lines, title, entries) {
  if (entries.length === 0) {
    lines.push(`${title}: nothing`);
    return;
  }
  lines.push(`${title}: ${files(entries.length)}`);
  for (const { key, reason } of entries) {
    lines.push(`  ${reason.padEnd(7)}  ${printable(key)}`);
  }
}

function files(n) {
  return `${n} ${n === 1 ? 'file' : 'files'}`;
}
