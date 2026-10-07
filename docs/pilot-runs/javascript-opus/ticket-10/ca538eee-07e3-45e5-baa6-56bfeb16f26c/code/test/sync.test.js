// sync() against a real Syncbox server running in-process on loopback, and
// planSync()'s decisions on their own.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';

import { RequestError, SyncboxClient, encodeKey } from '../src/client.js';
import { LocalConflictError } from '../src/pull.js';
import { createServer } from '../src/server.js';
import { loadState, stateDirectory, stateFile } from '../src/sync-state.js';
import { planSync, sync } from '../src/sync.js';

const sha256 = (data) => createHash('sha256').update(data).digest('hex');

async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}

async function writeTree(root, files) {
  for (const [rel, content] of Object.entries(files)) {
    await fs.mkdir(path.dirname(path.join(root, rel)), { recursive: true });
    await fs.writeFile(path.join(root, rel), content);
  }
}

/** Every file under `root` as "relative/path" -> contents; directories are left out. */
async function readFiles(root) {
  const out = {};
  for (const entry of await fs.readdir(root, { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) {
      const full = path.join(entry.path, entry.name);
      out[path.relative(root, full).split(path.sep).join('/')] = await fs.readFile(full, 'utf8');
    }
  }
  return out;
}

describe('planSync', () => {
  const T = Date.parse('2024-05-06T07:08:09.123Z');
  const local = (entries) => new Map(Object.entries(entries).map(([k, [sha, mtime]]) => [k, { sha256: sha, mtime }]));
  const remote = (entries) => new Map(Object.entries(entries).map(([k, [sha, ms]]) => [k, { sha256: sha, modified_at: new Date(ms).toISOString() }]));
  const plan = (l, r, base = {}) => planSync({ local: local(l), remote: remote(r), base: new Map(Object.entries(base)) });

  it('copies files that exist on one side only to the other, sorted by key', () => {
    assert.deepEqual(plan({ 'b.txt': ['l', T] }, { 'a.txt': ['r', T], 'c/d.txt': ['r', T] }), [
      { key: 'a.txt', action: 'download' },
      { key: 'b.txt', action: 'upload' },
      { key: 'c/d.txt', action: 'download' },
    ]);
  });

  it('copies one-sided files even if the other side had them at the last sync', () => {
    // Deletions are not propagated: a file gone from one side comes back.
    assert.deepEqual(plan({ 'a.txt': ['x', T] }, { 'b.txt': ['y', T] }, { 'a.txt': 'x', 'b.txt': 'y' }), [
      { key: 'a.txt', action: 'upload' },
      { key: 'b.txt', action: 'download' },
    ]);
  });

  it('leaves files with the same SHA-256 on both sides alone, whatever their times and base', () => {
    assert.deepEqual(plan({ 'a.txt': ['x', T] }, { 'a.txt': ['x', T + 5000] }, { 'a.txt': 'old' }), [{ key: 'a.txt', action: 'none' }]);
  });

  it('uploads a file changed only locally, even if the server copy is newer', () => {
    assert.deepEqual(plan({ 'a.txt': ['new', T] }, { 'a.txt': ['old', T + 60_000] }, { 'a.txt': 'old' }), [{ key: 'a.txt', action: 'upload' }]);
  });

  it('downloads a file changed only on the server, even if the local copy is newer', () => {
    assert.deepEqual(plan({ 'a.txt': ['old', T + 60_000] }, { 'a.txt': ['new', T] }, { 'a.txt': 'old' }), [{ key: 'a.txt', action: 'download' }]);
  });

  it('settles a file changed on both sides in favour of the newer copy', () => {
    const base = { 'a.txt': 'old', 'b.txt': 'old' };
    assert.deepEqual(plan({ 'a.txt': ['mine', T + 1] }, { 'a.txt': ['theirs', T] }, base), [{ key: 'a.txt', action: 'upload', conflict: 'local-newer' }]);
    assert.deepEqual(plan({ 'b.txt': ['mine', T] }, { 'b.txt': ['theirs', T + 1] }, base), [{ key: 'b.txt', action: 'download', conflict: 'server-newer' }]);
  });

  it('keeps the local copy when both sides changed at the same time', () => {
    assert.deepEqual(plan({ 'a.txt': ['mine', T] }, { 'a.txt': ['theirs', T] }, { 'a.txt': 'old' }), [{ key: 'a.txt', action: 'upload', conflict: 'same-time' }]);
  });

  it('applies the same rule to a file that differs when there is no common state yet', () => {
    assert.deepEqual(plan({ 'a.txt': ['mine', T], 'b.txt': ['mine', T + 1], 'c.txt': ['mine', T] }, { 'a.txt': ['theirs', T + 1], 'b.txt': ['theirs', T], 'c.txt': ['theirs', T] }), [
      { key: 'a.txt', action: 'download', conflict: 'server-newer' },
      { key: 'b.txt', action: 'upload', conflict: 'local-newer' },
      { key: 'c.txt', action: 'upload', conflict: 'same-time' },
    ]);
  });

  it('treats a file changed on both sides from a base neither has as a conflict', () => {
    assert.deepEqual(plan({ 'a.txt': ['mine', T] }, { 'a.txt': ['theirs', T + 1] }, { 'a.txt': 'unrelated' }), [{ key: 'a.txt', action: 'download', conflict: 'server-newer' }]);
  });

  it('keeps the local copy if the server time cannot be read', () => {
    const result = planSync({
      local: local({ 'a.txt': ['mine', T] }),
      remote: new Map([['a.txt', { sha256: 'theirs', modified_at: 'not a date' }]]),
      base: new Map([['a.txt', 'old']]),
    });
    assert.deepEqual(result, [{ key: 'a.txt', action: 'upload', conflict: 'local-newer' }]);
  });
});

describe('sync', () => {
  let tmp;
  let server;
  let baseUrl;
  let client;
  let dir;
  let dataDir;
  let stateDir;
  let requests;
  let serial = 0;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-sync-'));
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  beforeEach(async () => {
    const name = `case-${++serial}`;
    dir = path.join(tmp, name, 'local');
    dataDir = path.join(tmp, name, 'data');
    stateDir = path.join(tmp, name, 'state');
    await fs.mkdir(dir, { recursive: true });
    server = createServer({ dataDir });
    // Every request the server sees, as "METHOD path".
    requests = [];
    server.on('request', (req) => requests.push(`${req.method} ${req.url}`));
    baseUrl = await listen(server);
    client = new SyncboxClient(new URL(baseUrl));
  });

  afterEach(async () => {
    await close(server);
  });

  const run = (options = {}) => sync({ dir, client, stateDir, ...options });

  async function putBlobs(blobs) {
    for (const [key, content] of Object.entries(blobs)) {
      const res = await fetch(`${baseUrl}/blobs/${encodeKey(key)}`, { method: 'PUT', body: content });
      assert.equal(res.status, 201, key);
    }
  }

  /** Every blob on the server as key -> contents. */
  async function serverFiles() {
    const out = {};
    for (const { key } of await (await fetch(`${baseUrl}/blobs`)).json()) {
      out[key] = await (await fetch(`${baseUrl}/blobs/${encodeKey(key)}`)).text();
    }
    return out;
  }

  const setLocalTime = (key, time) => fs.utimes(path.join(dir, ...key.split('/')), time, time);
  const setServerTime = (key, time) => fs.utimes(path.join(dataDir, 'blobs', ...key.split('/')), time, time);

  /** Brings both sides to `files` with a sync, so that the next sync has them as its base. */
  async function syncedBaseline(files) {
    await writeTree(dir, files);
    await run();
    assert.deepEqual(await serverFiles(), files);
    requests.length = 0;
  }

  it('uploads files that exist only locally, byte for byte', async () => {
    const files = { 'readme.txt': 'hello\n', 'docs/deep/guide.md': '# Guide\n', 'empty': '', 'with space/ünï ?#%.txt': 'odd' };
    await writeTree(dir, files);
    const log = [];
    const result = await run({ log: (line) => log.push(line) });

    const keys = Object.keys(files).sort();
    assert.deepEqual(result, { uploaded: keys, downloaded: [], upToDate: [], conflicts: [] });
    assert.deepEqual(log, keys.map((k) => `uploaded ${k}`));
    assert.deepEqual(await serverFiles(), files);
    assert.deepEqual(await readFiles(dir), files);
  });

  it('downloads files that exist only on the server, creating subdirectories', async () => {
    const blobs = { 'a.txt': 'a', 'sub/deeper/b.bin': 'b', '.hidden/c': 'c' };
    await putBlobs(blobs);
    const log = [];
    const result = await run({ log: (line) => log.push(line) });

    const keys = Object.keys(blobs).sort();
    assert.deepEqual(result, { uploaded: [], downloaded: keys, upToDate: [], conflicts: [] });
    assert.deepEqual(log, keys.map((k) => `downloaded ${k}`));
    assert.deepEqual(await readFiles(dir), blobs);
    assert.deepEqual(await serverFiles(), blobs);
  });

  it('merges both sides in one pass and then has nothing left to do', async () => {
    await writeTree(dir, { 'local.txt': 'L', 'same.txt': 'S' });
    await putBlobs({ 'remote.txt': 'R', 'same.txt': 'S' });
    requests.length = 0;

    const first = await run();
    assert.deepEqual(first, { uploaded: ['local.txt'], downloaded: ['remote.txt'], upToDate: ['same.txt'], conflicts: [] });
    const both = { 'local.txt': 'L', 'remote.txt': 'R', 'same.txt': 'S' };
    assert.deepEqual(await readFiles(dir), both);
    assert.deepEqual(await serverFiles(), both);
    requests.length = 0;

    const second = await run();
    assert.deepEqual(second, { uploaded: [], downloaded: [], upToDate: ['local.txt', 'remote.txt', 'same.txt'], conflicts: [] });
    assert.deepEqual(requests, ['GET /blobs']);
  });

  it('uploads a file changed only locally, even if the server copy is newer', async () => {
    await syncedBaseline({ 'a.txt': 'original', 'b.txt': 'untouched' });
    await fs.writeFile(path.join(dir, 'a.txt'), 'local edit');
    // The rule for conflicts must not come into it: only one side changed.
    await setLocalTime('a.txt', new Date('2000-01-01T00:00:00Z'));

    const result = await run();
    assert.deepEqual(result, { uploaded: ['a.txt'], downloaded: [], upToDate: ['b.txt'], conflicts: [] });
    assert.deepEqual(requests, ['GET /blobs', 'PUT /blobs/a.txt']);
    assert.deepEqual(await serverFiles(), { 'a.txt': 'local edit', 'b.txt': 'untouched' });
    assert.deepEqual(await readFiles(dir), { 'a.txt': 'local edit', 'b.txt': 'untouched' });
  });

  it('downloads a file changed only on the server, even if the local copy is newer', async () => {
    await syncedBaseline({ 'a.txt': 'original', 'sub/b.txt': 'untouched' });
    await putBlobs({ 'sub/b.txt': 'server edit' });
    await setServerTime('sub/b.txt', new Date('2000-01-01T00:00:00Z'));
    requests.length = 0;

    const result = await run();
    assert.deepEqual(result, { uploaded: [], downloaded: ['sub/b.txt'], upToDate: ['a.txt'], conflicts: [] });
    assert.deepEqual(requests, ['GET /blobs', 'GET /blobs/sub/b.txt']);
    assert.deepEqual(await readFiles(dir), { 'a.txt': 'original', 'sub/b.txt': 'server edit' });
    assert.deepEqual(await serverFiles(), { 'a.txt': 'original', 'sub/b.txt': 'server edit' });
  });

  describe('a file changed on both sides', () => {
    const T = new Date('2024-05-06T07:08:09.123Z');
    const later = new Date(T.getTime() + 10_000);

    async function changeBoth({ localTime, serverTime }) {
      await syncedBaseline({ 'doc.txt': 'original', 'other.txt': 'other' });
      await fs.writeFile(path.join(dir, 'doc.txt'), 'local version');
      await putBlobs({ 'doc.txt': 'server version' });
      await setLocalTime('doc.txt', localTime);
      await setServerTime('doc.txt', serverTime);
      requests.length = 0;
    }

    it('goes to the server when the local copy is newer', async () => {
      await changeBoth({ localTime: later, serverTime: T });
      const log = [];
      const result = await run({ log: (line) => log.push(line) });
      assert.deepEqual(result, { uploaded: ['doc.txt'], downloaded: [], upToDate: ['other.txt'], conflicts: ['doc.txt'] });
      assert.deepEqual(log, ['uploaded doc.txt (changed on both sides, local copy is newer)']);
      assert.deepEqual(await serverFiles(), { 'doc.txt': 'local version', 'other.txt': 'other' });
      assert.deepEqual(await readFiles(dir), { 'doc.txt': 'local version', 'other.txt': 'other' });
    });

    it('comes from the server when the server copy is newer', async () => {
      await changeBoth({ localTime: T, serverTime: later });
      const log = [];
      const result = await run({ log: (line) => log.push(line) });
      assert.deepEqual(result, { uploaded: [], downloaded: ['doc.txt'], upToDate: ['other.txt'], conflicts: ['doc.txt'] });
      assert.deepEqual(log, ['downloaded doc.txt (changed on both sides, server copy is newer)']);
      assert.deepEqual(await readFiles(dir), { 'doc.txt': 'server version', 'other.txt': 'other' });
      assert.deepEqual(await serverFiles(), { 'doc.txt': 'server version', 'other.txt': 'other' });
    });

    it('keeps the local copy when both were modified at the same time', async () => {
      await changeBoth({ localTime: T, serverTime: T });
      const log = [];
      const result = await run({ log: (line) => log.push(line) });
      assert.deepEqual(result, { uploaded: ['doc.txt'], downloaded: [], upToDate: ['other.txt'], conflicts: ['doc.txt'] });
      assert.deepEqual(log, ['uploaded doc.txt (changed on both sides at the same time, local copy kept)']);
      assert.deepEqual(await serverFiles(), { 'doc.txt': 'local version', 'other.txt': 'other' });
      assert.deepEqual(await readFiles(dir), { 'doc.txt': 'local version', 'other.txt': 'other' });
    });

    it('is settled for good: the next sync has nothing to do', async () => {
      await changeBoth({ localTime: T, serverTime: later });
      await run();
      requests.length = 0;
      const result = await run();
      assert.deepEqual(result.upToDate, ['doc.txt', 'other.txt']);
      assert.deepEqual(requests, ['GET /blobs']);
    });
  });

  it('settles a file that differs at the first sync by modification time', async () => {
    await writeTree(dir, { 'newer-here.txt': 'local', 'newer-there.txt': 'local' });
    await putBlobs({ 'newer-here.txt': 'server', 'newer-there.txt': 'server' });
    const T = new Date('2024-01-01T00:00:00Z');
    const later = new Date('2024-01-02T00:00:00Z');
    await setLocalTime('newer-here.txt', later);
    await setServerTime('newer-here.txt', T);
    await setLocalTime('newer-there.txt', T);
    await setServerTime('newer-there.txt', later);

    const result = await run();
    assert.deepEqual(result.uploaded, ['newer-here.txt']);
    assert.deepEqual(result.downloaded, ['newer-there.txt']);
    const expected = { 'newer-here.txt': 'local', 'newer-there.txt': 'server' };
    assert.deepEqual(await readFiles(dir), expected);
    assert.deepEqual(await serverFiles(), expected);
  });

  it('deletes nothing: a file removed on one side comes back from the other', async () => {
    await syncedBaseline({ 'gone-locally.txt': 'g1', 'gone-on-server.txt': 'g2', 'kept.txt': 'k' });
    await fs.rm(path.join(dir, 'gone-locally.txt'));
    assert.equal((await fetch(`${baseUrl}/blobs/gone-on-server.txt`, { method: 'DELETE' })).status, 204);
    requests.length = 0;

    const result = await run();
    assert.deepEqual(result, { uploaded: ['gone-on-server.txt'], downloaded: ['gone-locally.txt'], upToDate: ['kept.txt'], conflicts: [] });
    assert.ok(!requests.some((r) => r.startsWith('DELETE ')), requests.join(', '));
    const all = { 'gone-locally.txt': 'g1', 'gone-on-server.txt': 'g2', 'kept.txt': 'k' };
    assert.deepEqual(await readFiles(dir), all);
    assert.deepEqual(await serverFiles(), all);
  });

  it('keeps its state outside the directory, one state per directory and server', async () => {
    await syncedBaseline({ 'a.txt': 'a' });
    // The directory holds the synced files and nothing else.
    assert.deepEqual(await fs.readdir(dir), ['a.txt']);
    const file = await stateFile(stateDir, client.base, dir);
    assert.equal(path.dirname(file), stateDir);
    assert.deepEqual(await loadState(file), new Map([['a.txt', sha256('a')]]));
    assert.notEqual(await stateFile(stateDir, 'http://127.0.0.1:1', dir), file);
    assert.notEqual(await stateFile(stateDir, client.base, tmp), file);
  });

  it('remembers what was in common before a failure, and not keys that are gone from both sides', async () => {
    await syncedBaseline({ 'a.txt': 'a', 'b.txt': 'b', 'gone.txt': 'g' });
    await fs.writeFile(path.join(dir, 'a.txt'), 'a2');
    await fs.rm(path.join(dir, 'gone.txt'));
    assert.equal((await fetch(`${baseUrl}/blobs/gone.txt`, { method: 'DELETE' })).status, 204);
    await putBlobs({ 'b.txt': 'b2', 'blocked.txt': 'blocked' });
    await fs.mkdir(path.join(dir, 'blocked.txt'));
    await writeTree(dir, { 'z.txt': 'z' });

    await assert.rejects(run(), LocalConflictError);
    const file = await stateFile(stateDir, client.base, dir);
    // a.txt and b.txt were transferred before the failure; z.txt was not reached.
    assert.deepEqual(await loadState(file), new Map([['a.txt', sha256('a2')], ['b.txt', sha256('b2')], ['gone.txt', sha256('g')]]));

    await fs.rmdir(path.join(dir, 'blocked.txt'));
    await run();
    assert.deepEqual(
      await loadState(file),
      new Map([['a.txt', sha256('a2')], ['b.txt', sha256('b2')], ['blocked.txt', sha256('blocked')], ['z.txt', sha256('z')]]),
    );
  });

  it('skips symbolic links on both sides, reporting them', async () => {
    const outside = path.join(dir, '..', 'outside');
    await writeTree(outside, { 'target.txt': 'outside file' });
    await fs.symlink(outside, path.join(dir, 'linked-dir'));
    await writeTree(dir, { 'ok.txt': 'ok' });
    await putBlobs({ 'linked-dir/target.txt': 'overwritten?' });

    const warnings = [];
    const result = await run({ warn: (line) => warnings.push(line) });
    assert.deepEqual(result, { uploaded: ['ok.txt'], downloaded: [], upToDate: [], conflicts: [] });
    assert.deepEqual(warnings, ['skipping linked-dir: symbolic link', 'skipping linked-dir/target.txt: linked-dir is a symbolic link']);
    assert.deepEqual(await readFiles(outside), { 'target.txt': 'outside file' });
  });

  it('fails promptly when nothing listens at the URL, changing nothing', async () => {
    const probe = net.createServer();
    const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
    await new Promise((resolve) => probe.close(resolve));
    await writeTree(dir, { 'a.txt': 'a' });

    const unreachable = new SyncboxClient(new URL(`http://127.0.0.1:${port}`));
    await assert.rejects(sync({ dir, client: unreachable, stateDir }), (err) => {
      assert.ok(err instanceof RequestError);
      assert.match(err.message, /^cannot reach server .*ECONNREFUSED/);
      return true;
    });
    assert.deepEqual(await readFiles(dir), { 'a.txt': 'a' });
    await assert.rejects(fs.stat(stateDir), { code: 'ENOENT' });
  });

  it('fails when the directory does not exist, before contacting the server', async () => {
    await assert.rejects(sync({ dir: path.join(dir, 'missing'), client, stateDir }), { code: 'ENOENT' });
    assert.deepEqual(requests, []);
  });

  it('stops when aborted, leaving the server untouched', async () => {
    await writeTree(dir, { 'a.txt': 'a' });
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(run({ signal: controller.signal }), { name: 'AbortError' });
    assert.deepEqual(await serverFiles(), {});
  });
});

describe('stateDirectory', () => {
  it('prefers SYNCBOX_STATE_DIR, then XDG_STATE_HOME, then ~/.local/state', () => {
    assert.equal(stateDirectory({ SYNCBOX_STATE_DIR: '/s', XDG_STATE_HOME: '/x' }), '/s');
    assert.equal(stateDirectory({ SYNCBOX_STATE_DIR: '', XDG_STATE_HOME: '/x' }), path.join('/x', 'syncbox'));
    assert.equal(stateDirectory({}), path.join(os.homedir(), '.local', 'state', 'syncbox'));
  });
});
