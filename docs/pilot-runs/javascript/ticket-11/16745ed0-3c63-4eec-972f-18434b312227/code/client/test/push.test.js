'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { run } = require('../src/push');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
}

// A minimal in-memory stand-in for the real Syncbox server: just enough of
// GET /blobs and PUT /blobs/{key} for push() to exercise against, without
// coupling client tests to the server package.
function startFakeServer() {
  const store = new Map(); // key -> { buffer, sha256 }
  const puts = [];

  const server = http.createServer((req, res) => {
    const pathname = req.url.split('?')[0];

    if (req.method === 'GET' && pathname === '/blobs') {
      const list = [...store.entries()].map(([key, blob]) => ({
        key,
        size: blob.buffer.length,
        sha256: blob.sha256,
        modified_at: new Date(0).toISOString(),
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
        const sha256 = crypto.createHash('sha256').update(buffer).digest('hex');
        store.set(key, { buffer, sha256 });
        puts.push(key);
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ key, sha256, size: buffer.length }));
      });
      return;
    }

    res.writeHead(404);
    res.end();
  });

  return { server, store, puts };
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

test('push uploads every file when the server is empty', async (t) => {
  const { server, store, puts } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');
  fs.mkdirSync(path.join(dir, 'docs'));
  fs.writeFileSync(path.join(dir, 'docs', 'readme.txt'), '# readme');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.uploaded.sort(), ['a.txt', 'docs/readme.txt']);
  assert.deepEqual(result.skipped, []);
  assert.deepEqual(puts.sort(), ['a.txt', 'docs/readme.txt']);
  assert.equal(store.get('a.txt').buffer.toString(), 'hello');
  assert.equal(store.get('docs/readme.txt').buffer.toString(), '# readme');
});

test('push skips a file whose content already matches the server copy', async (t) => {
  const { server, puts } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');
  const serverUrl = `http://127.0.0.1:${port}`;

  await run({ dir, serverUrl });
  puts.length = 0;

  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, []);
  assert.deepEqual(result.skipped, ['a.txt']);
  assert.deepEqual(puts, []);
});

test('push re-uploads a file whose content changed since the last push', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'hello');
  const serverUrl = `http://127.0.0.1:${port}`;

  await run({ dir, serverUrl });
  fs.writeFileSync(filePath, 'hello, changed');
  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['a.txt']);
  assert.equal(store.get('a.txt').buffer.toString(), 'hello, changed');
});

test('push uploads only new/changed files, leaving matching ones alone', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const serverUrl = `http://127.0.0.1:${port}`;
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');
  await run({ dir, serverUrl });

  fs.writeFileSync(path.join(dir, 'b.txt'), 'world');
  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, ['b.txt']);
  assert.deepEqual(result.skipped, ['a.txt']);
  assert.equal(store.size, 2);
});

test('push does not re-upload a same-content file even if the local mtime changed', async (t) => {
  const { server, puts } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'hello');
  const serverUrl = `http://127.0.0.1:${port}`;

  await run({ dir, serverUrl });
  puts.length = 0;

  // Rewrite the exact same bytes - mtime changes, sha256 does not.
  fs.writeFileSync(filePath, 'hello');
  const result = await run({ dir, serverUrl });

  assert.deepEqual(result.uploaded, []);
  assert.deepEqual(puts, []);
});

test('push handles nested keys with the same POSIX-key convention as the server', async (t) => {
  const { server, store } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.mkdirSync(path.join(dir, 'a', 'b'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'a', 'b', 'c.txt'), 'deep');

  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.ok(store.has('a/b/c.txt'));
});

test('push throws a clear error when <dir> does not exist', async () => {
  const dir = path.join(os.tmpdir(), `syncbox-client-test-missing-${crypto.randomBytes(4).toString('hex')}`);
  await assert.rejects(
    () => run({ dir, serverUrl: 'http://127.0.0.1:1' }),
    /not a directory/
  );
});

test('push throws a clear error instead of hanging when the server is unreachable', async () => {
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  await assert.rejects(() => run({ dir, serverUrl: 'http://127.0.0.1:1' }), /connection refused/i);
});

test('push continues past a server 5xx on one file, still uploads the rest, and reports the failure', async (t) => {
  const stored = new Map(); // key -> Buffer

  const server = http.createServer((req, res) => {
    const pathname = req.url.split('?')[0];

    if (req.method === 'GET' && pathname === '/blobs') {
      const list = [...stored.entries()].map(([key, buffer]) => ({
        key,
        size: buffer.length,
        sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
        modified_at: new Date(0).toISOString(),
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
        if (key === 'bad.txt') {
          res.writeHead(500, { 'Content-Type': 'text/plain' });
          res.end('internal error');
          return;
        }
        const buffer = Buffer.concat(chunks);
        stored.set(key, buffer);
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ key, sha256: crypto.createHash('sha256').update(buffer).digest('hex'), size: buffer.length }));
      });
      return;
    }

    res.writeHead(404);
    res.end();
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'good.txt'), 'hello');
  fs.writeFileSync(path.join(dir, 'bad.txt'), 'will fail');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.uploaded, ['good.txt']);
  assert.equal(result.failed.length, 1);
  assert.equal(result.failed[0].key, 'bad.txt');
  assert.match(result.failed[0].error, /status 500/);
  assert.equal(stored.get('good.txt').toString(), 'hello');
  assert.equal(stored.has('bad.txt'), false);
});
