'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { run } = require('../src/sync');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
}

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

// A minimal in-memory stand-in for the real Syncbox server: enough of
// GET /blobs, GET /blobs/{key} and PUT /blobs/{key} for sync() to exercise
// against, without coupling client tests to the server package. Unlike the
// push/pull/status fake servers, this one tracks a real modified_at per key
// (defaulting to epoch when seeded, updated to "now" on PUT) and exposes a
// `seed` helper to set content and modified_at directly - simulating a
// change made on the server by something other than this client, which is
// exactly what the conflict-resolution tests need to control.
function startFakeServer(initial = {}) {
  const store = new Map(); // key -> { buffer, modifiedAt: Date }
  const puts = [];
  const gets = [];

  for (const [key, content] of Object.entries(initial)) {
    store.set(key, { buffer: Buffer.from(content), modifiedAt: new Date(0) });
  }

  const server = http.createServer((req, res) => {
    const pathname = req.url.split('?')[0];

    if (req.method === 'GET' && pathname === '/blobs') {
      const list = [...store.entries()].map(([key, blob]) => ({
        key,
        size: blob.buffer.length,
        sha256: sha256(blob.buffer),
        modified_at: blob.modifiedAt.toISOString(),
      }));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(list));
      return;
    }

    const match = pathname.match(/^\/blobs\/(.+)$/);
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

    if (match && req.method === 'PUT') {
      const key = decodeURIComponent(match[1]);
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const buffer = Buffer.concat(chunks);
        store.set(key, { buffer, modifiedAt: new Date() });
        puts.push(key);
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ key, sha256: sha256(buffer), size: buffer.length }));
      });
      return;
    }

    res.writeHead(404);
    res.end();
  });

  return {
    server,
    store,
    puts,
    gets,
    seed(key, content, modifiedAt) {
      store.set(key, { buffer: Buffer.from(content), modifiedAt });
    },
  };
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

test('sync uploads a file that exists only locally', async (t) => {
  const fake = startFakeServer();
  const port = await listen(fake.server);
  t.after(() => fake.server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.uploaded, ['local-only.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.equal(fake.store.get('local-only.txt').buffer.toString(), 'hello');
});

test('sync downloads a file that exists only on the server', async (t) => {
  const fake = startFakeServer({ 'remote-only.txt': 'from server' });
  const port = await listen(fake.server);
  t.after(() => fake.server.close());

  const dir = tempDir();

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['remote-only.txt']);
  assert.deepEqual(result.uploaded, []);
  assert.equal(fs.readFileSync(path.join(dir, 'remote-only.txt'), 'utf8'), 'from server');
});

test('sync does not delete local files absent from the server, nor server blobs absent locally', async (t) => {
  const fake = startFakeServer({ 'remote-only.txt': 'from server' });
  const port = await listen(fake.server);
  t.after(() => fake.server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'from local');

  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.equal(fs.readFileSync(path.join(dir, 'local-only.txt'), 'utf8'), 'from local');
  assert.ok(fake.store.has('remote-only.txt'));
});

test('sync uploads a file changed only locally since the last sync', async (t) => {
  const fake = startFakeServer();
  const port = await listen(fake.server);
  t.after(() => fake.server.close());
  const serverUrl = `http://127.0.0.1:${port}`;

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'shared');

  // First sync establishes the common baseline (uploads the local-only file).
  await run({ dir, serverUrl });
  assert.equal(fake.store.get('a.txt').buffer.toString(), 'shared');

  // Only the local copy changes; give it an older mtime than the
  // untouched server copy would compare against, to prove the resolution
  // is unconditional (baseline-driven), not an mtime race.
  fs.writeFileSync(filePath, 'shared, locally changed');
  fs.utimesSync(filePath, new Date(0), new Date(0));

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.equal(fake.store.get('a.txt').buffer.toString(), 'shared, locally changed');
});

test('sync downloads a file changed only on the server since the last sync', async (t) => {
  const fake = startFakeServer();
  const port = await listen(fake.server);
  t.after(() => fake.server.close());
  const serverUrl = `http://127.0.0.1:${port}`;

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'shared');

  await run({ dir, serverUrl });

  // Only the server copy changes (simulating another client), with a
  // modified_at in the past relative to the untouched local file's mtime,
  // to prove the resolution is unconditional, not an mtime race.
  fake.seed('a.txt', 'shared, changed on server', new Date(0));

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.deepEqual(result.uploaded, []);
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'shared, changed on server');
});

test('sync conflict: both sides changed, the newer one (by modified_at/mtime) wins', async (t) => {
  const fake = startFakeServer();
  const port = await listen(fake.server);
  t.after(() => fake.server.close());
  const serverUrl = `http://127.0.0.1:${port}`;

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'shared');

  await run({ dir, serverUrl });

  // Local change is newer than the server's change.
  fs.writeFileSync(filePath, 'local edit');
  fs.utimesSync(filePath, new Date('2024-01-02T00:00:00Z'), new Date('2024-01-02T00:00:00Z'));
  fake.seed('a.txt', 'server edit', new Date('2024-01-01T00:00:00Z'));

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.equal(fake.store.get('a.txt').buffer.toString(), 'local edit');
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'local edit');
});

test('sync conflict: the server change is newer, so the server version wins', async (t) => {
  const fake = startFakeServer();
  const port = await listen(fake.server);
  t.after(() => fake.server.close());
  const serverUrl = `http://127.0.0.1:${port}`;

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'shared');

  await run({ dir, serverUrl });

  fs.writeFileSync(filePath, 'local edit');
  fs.utimesSync(filePath, new Date('2024-01-01T00:00:00Z'), new Date('2024-01-01T00:00:00Z'));
  fake.seed('a.txt', 'server edit', new Date('2024-01-02T00:00:00Z'));

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.deepEqual(result.uploaded, []);
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'server edit');
  assert.equal(fake.store.get('a.txt').buffer.toString(), 'server edit');
});

test('sync conflict: equal modified_at/mtime, the local version wins', async (t) => {
  const fake = startFakeServer();
  const port = await listen(fake.server);
  t.after(() => fake.server.close());
  const serverUrl = `http://127.0.0.1:${port}`;

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'shared');

  await run({ dir, serverUrl });

  const tie = new Date('2024-01-01T00:00:00Z');
  fs.writeFileSync(filePath, 'local edit');
  fs.utimesSync(filePath, tie, tie);
  fake.seed('a.txt', 'server edit', tie);

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.deepEqual(result.downloaded, []);
  assert.equal(fake.store.get('a.txt').buffer.toString(), 'local edit');
  assert.equal(fs.readFileSync(filePath, 'utf8'), 'local edit');
});

test('sync leaves a file untouched when local and server already match', async (t) => {
  const fake = startFakeServer({ 'a.txt': 'same everywhere' });
  const port = await listen(fake.server);
  t.after(() => fake.server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'same everywhere');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.uploaded, []);
  assert.deepEqual(result.downloaded, []);
  assert.deepEqual(result.unchanged, ['a.txt']);
  assert.deepEqual(fake.puts, []);
  assert.deepEqual(fake.gets, []);
});

test('sync handles nested keys with the same POSIX-key convention as the server, creating subdirectories', async (t) => {
  const fake = startFakeServer({ 'srv/deep.txt': 'from server' });
  const port = await listen(fake.server);
  t.after(() => fake.server.close());

  const dir = tempDir();
  fs.mkdirSync(path.join(dir, 'a', 'b'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'a', 'b', 'c.txt'), 'from local');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.uploaded, ['a/b/c.txt']);
  assert.deepEqual(result.downloaded, ['srv/deep.txt']);
  assert.ok(fake.store.has('a/b/c.txt'));
  assert.equal(fs.readFileSync(path.join(dir, 'srv', 'deep.txt'), 'utf8'), 'from server');
});

test('sync does not treat its own bookkeeping directory as a syncable file', async (t) => {
  const fake = startFakeServer();
  const port = await listen(fake.server);
  t.after(() => fake.server.close());
  const serverUrl = `http://127.0.0.1:${port}`;

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  await run({ dir, serverUrl });
  assert.ok(fs.existsSync(path.join(dir, '.syncbox', 'manifest.json')));

  // A second run walks the directory again, now that .syncbox/manifest.json
  // exists on disk - it must still be excluded from what gets synced.
  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, []);
  assert.deepEqual([...fake.store.keys()], ['a.txt']);
});

test('sync creates the target directory if it does not exist yet', async (t) => {
  const fake = startFakeServer({ 'a.txt': 'hello' });
  const port = await listen(fake.server);
  t.after(() => fake.server.close());

  const dir = path.join(os.tmpdir(), `syncbox-client-test-missing-${crypto.randomBytes(4).toString('hex')}`);
  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.equal(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'hello');
});

test('sync throws a clear error instead of hanging when the server is unreachable', async () => {
  const dir = tempDir();
  await assert.rejects(() => run({ dir, serverUrl: 'http://127.0.0.1:1' }));
});
