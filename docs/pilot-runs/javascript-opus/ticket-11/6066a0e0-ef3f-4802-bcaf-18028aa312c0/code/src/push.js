import { Failures } from './failures.js';
import { listFiles, sha256File } from './local-files.js';

/**
 * Uploads every file under `dir` that the server lacks or holds with
 * different contents. Files whose SHA-256 matches the server's copy are not
 * sent again. Nothing is deleted on either side.
 *
 * A file that fails (cannot be read, the server rejects it or the request
 * breaks off) is recorded in `failed` and the rest are still uploaded; see
 * Failures for when the rest are given up on (`stopped`).
 *
 * @param {{
 *   dir: string,
 *   client: import('./client.js').SyncboxClient,
 *   log?: (line: string) => void,   progress, one line per uploaded file
 *   warn?: (line: string) => void,  files left out
 * }} options
 * @returns {Promise<{
 *   uploaded: string[],
 *   upToDate: string[],
 *   failed: Array<{ key: string, reason: string, error: Error }>,
 *   stopped?: { error: import('./client.js').UnreachableError, remaining: number },
 * }>} keys
 * @throws {import('./client.js').RequestError} if the server's list cannot be had
 */
export async function push({ dir, client, log = () => {}, warn = () => {} }) {
  const failures = new Failures();
  const files = await listFiles(dir, {
    onSkip: (relPath, reason) => warn(`skipping ${relPath}: ${reason}`),
    onError: (relPath, err) => failures.add(`${relPath}/`, err),
  });
  const remote = new Map((await client.list()).map((blob) => [blob.key, blob.sha256]));

  const uploaded = [];
  const upToDate = [];
  await failures.each(files, 'upload', async ({ key, path }) => {
    if (remote.get(key) === (await sha256File(path))) {
      upToDate.push(key);
      return;
    }
    await client.put(key, path);
    uploaded.push(key);
    log(`uploaded ${key}`);
  });
  return { uploaded, upToDate, ...failures.result() };
}
