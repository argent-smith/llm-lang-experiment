'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { run } = require('../src/status');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
}

// A minimal in-memory stand-in for the real Syncbox server: just enough of
// GET /blobs for status() to exercise against, without coupling client tests
// to the server package. Tracks every mutating request it receives (PUT,
// DELETE, or GET on a specific blob) so tests can assert status never made
// one - it is required to be strictly read-only.
function startFakeServer(initial = {}) {
  const store = new Map(); // key -> Buffer
  const mutatingRequests = [];
  const blobGets = [];

  for (const [key, content] of Object.entries(initial)) {
    store.set(key, Buffer.from(content));
  }

  const server = http.createServer((req, res) => {
    const pathname = req.url.split('?')[0];

    if (req.method === 'GET' && pathname === '/blobs') {
      const list = [...store.entries()].map(([key, buffer]) => ({
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
    if (match) {
      const key = decodeURIComponent(match[1]);
      if (req.method === 'GET') {
        blobGets.push(key);
        const buffer = store.get(key);
        if (!buffer) {
          res.writeHead(404);
          res.end();
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
        res.end(buffer);
        return;
      }
      if (req.method === 'PUT' || req.method === 'DELETE') {
        mutatingRequests.push({ method: req.method, key });
        res.writeHead(req.method === 'PUT' ? 201 : 204);
        res.end();
        return;
      }
    }

    res.writeHead(404);
    res.end();
  });

  return { server, store, mutatingRequests, blobGets };
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

test('status reports a locally-new file as an upload, not a download', async (t) => {
  const { server, mutatingRequests } = startFakeServer();
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.toUpload, ['local-only.txt']);
  assert.deepEqual(result.toDownload, []);
  assert.deepEqual(mutatingRequests, []);
});

test('status reports a server-only file as a download, not an upload', async (t) => {
  const { server, mutatingRequests } = startFakeServer({ 'remote-only.txt': 'hello' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.toUpload, []);
  assert.deepEqual(result.toDownload, ['remote-only.txt']);
  assert.deepEqual(mutatingRequests, []);
});

test('status reports a file that differs in content on both sides, since it needs both an upload and a download to reconcile', async (t) => {
  const { server, mutatingRequests } = startFakeServer({ 'a.txt': 'server version' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'local version');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.toUpload, ['a.txt']);
  assert.deepEqual(result.toDownload, ['a.txt']);
  assert.deepEqual(mutatingRequests, []);
});

test('status reports no differences when local and server already match', async (t) => {
  const { server, mutatingRequests } = startFakeServer({ 'a.txt': 'hello' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.toUpload, []);
  assert.deepEqual(result.toDownload, []);
  assert.deepEqual(mutatingRequests, []);
});

test('status does not write, modify, or delete anything on the server', async (t) => {
  const { server, mutatingRequests } = startFakeServer({
    'a.txt': 'server version',
    'remote-only.txt': 'keep me',
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'local version');
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'keep me too');

  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(mutatingRequests, []);
});

test('status does not create, modify, or delete any local file', async (t) => {
  const { server } = startFakeServer({
    'a.txt': 'server version',
    'remote-only.txt': 'from server',
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'local version');
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'from local');

  const beforeEntries = fs.readdirSync(dir).sort();
  const beforeContents = {
    'a.txt': fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'),
    'local-only.txt': fs.readFileSync(path.join(dir, 'local-only.txt'), 'utf8'),
  };

  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(fs.readdirSync(dir).sort(), beforeEntries);
  assert.equal(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), beforeContents['a.txt']);
  assert.equal(fs.readFileSync(path.join(dir, 'local-only.txt'), 'utf8'), beforeContents['local-only.txt']);
  assert.equal(fs.existsSync(path.join(dir, 'remote-only.txt')), false);
});

test('status combines uploads, downloads, and unchanged files correctly in one comparison', async (t) => {
  const { server, mutatingRequests } = startFakeServer({
    'unchanged.txt': 'same everywhere',
    'server-only.txt': 'only on server',
    'changed.txt': 'server side',
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'unchanged.txt'), 'same everywhere');
  fs.writeFileSync(path.join(dir, 'changed.txt'), 'local side');
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'only on local');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.toUpload.sort(), ['changed.txt', 'local-only.txt']);
  assert.deepEqual(result.toDownload.sort(), ['changed.txt', 'server-only.txt']);
  assert.deepEqual(mutatingRequests, []);
});

test('status handles nested keys with the same POSIX-key convention as the server', async (t) => {
  const { server } = startFakeServer({ 'a/b/remote.txt': 'from server' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.mkdirSync(path.join(dir, 'x', 'y'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'x', 'y', 'local.txt'), 'from local');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.toUpload, ['x/y/local.txt']);
  assert.deepEqual(result.toDownload, ['a/b/remote.txt']);
});

test('status throws a clear error when <dir> does not exist', async () => {
  const dir = path.join(os.tmpdir(), `syncbox-client-test-missing-${crypto.randomBytes(4).toString('hex')}`);
  await assert.rejects(
    () => run({ dir, serverUrl: 'http://127.0.0.1:1' }),
    /not a directory/
  );
});

test('status throws a clear error instead of hanging when the server is unreachable', async () => {
  const dir = tempDir();
  await assert.rejects(() => run({ dir, serverUrl: 'http://127.0.0.1:1' }), /connection refused/i);
});
