'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { run, MANIFEST_FILENAME } = require('../src/sync');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
}

function sha256(content) {
  return crypto.createHash('sha256').update(content).digest('hex');
}

// A minimal in-memory stand-in for the real Syncbox server: GET /blobs,
// PUT /blobs/{key}, GET /blobs/{key}. Unlike the real server, modified_at is
// tracked explicitly per stored blob (defaulting to a fixed epoch timestamp
// on initial seed data, and to "now" on a real PUT) so tests can control it
// precisely to exercise the mtime conflict rule.
function startFakeServer(initial = {}) {
  const store = new Map(); // key -> { buffer, sha256, modifiedAt }
  const puts = [];
  const gets = [];

  for (const [key, entry] of Object.entries(initial)) {
    const buffer = Buffer.from(entry.content);
    store.set(key, {
      buffer,
      sha256: sha256(buffer),
      modifiedAt: entry.modifiedAt || new Date(0).toISOString(),
    });
  }

  const server = http.createServer((req, res) => {
    const pathname = req.url.split('?')[0];

    if (req.method === 'GET' && pathname === '/blobs') {
      const list = [...store.entries()].map(([key, blob]) => ({
        key,
        size: blob.buffer.length,
        sha256: blob.sha256,
        modified_at: blob.modifiedAt,
      }));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(list));
      return;
    }

    const match = pathname.match(/^\/blobs\/(.+)$/);
    if (match && req.method === 'PUT') {
      const key = decodeURIComponent(match[1]);
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const buffer = Buffer.concat(chunks);
        const digest = sha256(buffer);
        store.set(key, { buffer, sha256: digest, modifiedAt: new Date().toISOString() });
        puts.push(key);
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ key, sha256: digest, size: buffer.length }));
      });
      return;
    }

    if (match && req.method === 'GET') {
      const key = decodeURIComponent(match[1]);
      gets.push(key);
      const blob = store.get(key);
      if (!blob) {
        res.writeHead(404);
        res.end();
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(blob.buffer);
      return;
    }

    res.writeHead(404);
    res.end();
  });

  return { server, store, puts, gets };
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

// Sets a file's mtime to an exact whole-second timestamp, sidestepping any
// sub-second truncation differences between filesystems.
function setMtime(filePath, epochMs) {
  const seconds = epochMs / 1000;
  fs.utimesSync(filePath, seconds, seconds);
}

test('sync uploads a local-only file to the server', async (t) => {
  const { server, store, puts } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.deepEqual(puts, ['a.txt']);
  assert.equal(store.get('a.txt').buffer.toString(), 'hello');
});

test('sync downloads a server-only file to local', async (t) => {
  const { server, gets } = startFakeServer({ 'remote.txt': { content: 'from server' } });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['remote.txt']);
  assert.deepEqual(result.uploaded, []);
  assert.deepEqual(gets, ['remote.txt']);
  assert.equal(fs.readFileSync(path.join(dir, 'remote.txt'), 'utf8'), 'from server');
});

test('sync does not upload or download its own manifest file', async (t) => {
  const { server, puts } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');
  const serverUrl = `http://127.0.0.1:${port}`;

  const result = await run({ dir, serverUrl });

  assert.ok(fs.existsSync(path.join(dir, MANIFEST_FILENAME)));
  assert.deepEqual(puts, ['a.txt']);
  assert.deepEqual(result.uploaded, ['a.txt']);

  // A second run must not try to sync the manifest file it just wrote.
  const result2 = await run({ dir, serverUrl });
  assert.deepEqual(result2.uploaded, []);
  assert.deepEqual(result2.downloaded, []);
});

test('sync does not delete local files absent from the server', async (t) => {
  const { server } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'keep me');

  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.equal(fs.readFileSync(path.join(dir, 'local-only.txt'), 'utf8'), 'keep me');
});

test('sync does not delete server files absent locally', async (t) => {
  const { server, store } = startFakeServer({ 'remote-only.txt': { content: 'keep me' } });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.ok(store.has('remote-only.txt'));
});

test('sync creates subdirectories for nested keys downloaded from the server', async (t) => {
  const { server } = startFakeServer({ 'a/b/c.txt': { content: 'deep' } });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.equal(fs.readFileSync(path.join(dir, 'a', 'b', 'c.txt'), 'utf8'), 'deep');
});

test('a file changed only locally since the last sync ends up with the local version on the server', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'v1');
  const serverUrl = `http://127.0.0.1:${port}`;

  // First sync establishes the common baseline (v1 on both sides).
  await run({ dir, serverUrl });
  assert.equal(store.get('a.txt').buffer.toString(), 'v1');

  // Only the local copy changes.
  fs.writeFileSync(filePath, 'v2-local');

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.equal(store.get('a.txt').buffer.toString(), 'v2-local');
});

test('a file changed only on the server since the last sync ends up with the server version locally', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'v1');
  const serverUrl = `http://127.0.0.1:${port}`;

  // First sync establishes the common baseline (v1 on both sides).
  await run({ dir, serverUrl });

  // Only the server copy changes (simulating another client's push).
  const buffer = Buffer.from('v2-server');
  store.set('a.txt', { buffer, sha256: sha256(buffer), modifiedAt: new Date().toISOString() });

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.deepEqual(result.uploaded, []);
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'v2-server');
});

test('a genuine conflict (both sides changed) is resolved in favor of the fresher modified_at/mtime - local newer', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'v1');
  const serverUrl = `http://127.0.0.1:${port}`;

  await run({ dir, serverUrl });

  const base = Date.parse('2020-01-01T00:00:00.000Z');
  const buffer = Buffer.from('v2-server');
  store.set('a.txt', { buffer, sha256: sha256(buffer), modifiedAt: new Date(base).toISOString() });

  fs.writeFileSync(filePath, 'v2-local');
  setMtime(filePath, base + 10_000); // local is 10s newer than the server change

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.equal(store.get('a.txt').buffer.toString(), 'v2-local');
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'v2-local');
});

test('a genuine conflict (both sides changed) is resolved in favor of the fresher modified_at/mtime - server newer', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'v1');
  const serverUrl = `http://127.0.0.1:${port}`;

  await run({ dir, serverUrl });

  const base = Date.parse('2020-01-01T00:00:00.000Z');
  fs.writeFileSync(filePath, 'v2-local');
  setMtime(filePath, base);

  const buffer = Buffer.from('v2-server');
  store.set('a.txt', { buffer, sha256: sha256(buffer), modifiedAt: new Date(base + 10_000).toISOString() });

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.deepEqual(result.uploaded, []);
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'v2-server');
});

test('a genuine conflict with equal modified_at/mtime is resolved in favor of the local version', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'v1');
  const serverUrl = `http://127.0.0.1:${port}`;

  await run({ dir, serverUrl });

  const tie = Date.parse('2020-01-01T00:00:00.000Z');

  fs.writeFileSync(filePath, 'v2-local');
  setMtime(filePath, tie);

  const buffer = Buffer.from('v2-server');
  store.set('a.txt', { buffer, sha256: sha256(buffer), modifiedAt: new Date(tie).toISOString() });

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.equal(store.get('a.txt').buffer.toString(), 'v2-local');
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'v2-local');
});

test('sync leaves already-matching files untouched on both sides', async (t) => {
  const { server, puts, gets } = startFakeServer({ 'a.txt': { content: 'hello' } });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');
  const serverUrl = `http://127.0.0.1:${port}`;

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, []);
  assert.deepEqual(result.downloaded, []);
  assert.deepEqual(result.unchanged, ['a.txt']);
  assert.deepEqual(puts, []);
  assert.deepEqual(gets, []);
});

test('sync creates the target directory if it does not exist yet', async (t) => {
  const { server } = startFakeServer({ 'a.txt': { content: 'hello' } });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = path.join(os.tmpdir(), `syncbox-client-test-missing-${crypto.randomBytes(4).toString('hex')}`);
  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.equal(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'hello');
});

test('sync throws a clear error instead of hanging when the server is unreachable', async () => {
  const dir = tempDir();
  await assert.rejects(() => run({ dir, serverUrl: 'http://127.0.0.1:1' }));
});
