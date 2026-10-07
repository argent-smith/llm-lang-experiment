import { listFiles, sha256File } from './local-files.js';

/**
 * Uploads every file under `dir` that the server lacks or holds with
 * different contents. Files whose SHA-256 matches the server's copy are not
 * sent again. Nothing is deleted on either side. Stops at the first failure.
 *
 * @param {{
 *   dir: string,
 *   client: import('./client.js').SyncboxClient,
 *   log?: (line: string) => void,   progress, one line per uploaded file
 *   warn?: (line: string) => void,  files left out
 * }} options
 * @returns {Promise<{ uploaded: string[], upToDate: string[] }>} keys
 */
export async function push({ dir, client, log = () => {}, warn = () => {} }) {
  const files = await listFiles(dir, {
    onSkip: (relPath, reason) => warn(`skipping ${relPath}: ${reason}`),
  });
  const remote = new Map((await client.list()).map((blob) => [blob.key, blob.sha256]));

  const uploaded = [];
  const upToDate = [];
  for (const { key, path } of files) {
    if (remote.get(key) === (await sha256File(path))) {
      upToDate.push(key);
      continue;
    }
    await client.put(key, path);
    uploaded.push(key);
    log(`uploaded ${key}`);
  }
  return { uploaded, upToDate };
}
