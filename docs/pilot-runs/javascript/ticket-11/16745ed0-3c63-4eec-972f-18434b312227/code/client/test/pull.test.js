'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { run } = require('../src/pull');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
}

// A minimal in-memory stand-in for the real Syncbox server: just enough of
// GET /blobs and GET /blobs/{key} for pull() to exercise against, without
// coupling client tests to the server package.
function startFakeServer(initial = {}) {
  const store = new Map(); // key -> Buffer
  const gets = [];

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
    if (match && req.method === 'GET') {
      const key = decodeURIComponent(match[1]);
      gets.push(key);
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

    res.writeHead(404);
    res.end();
  });

  return { server, store, gets };
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

test('pull downloads every blob when the local directory is empty', async (t) => {
  const { server, gets } = startFakeServer({
    'a.txt': 'hello',
    'docs/readme.txt': '# readme',
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded.sort(), ['a.txt', 'docs/readme.txt']);
  assert.deepEqual(result.skipped, []);
  assert.deepEqual(gets.sort(), ['a.txt', 'docs/readme.txt']);
  assert.equal(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'hello');
  assert.equal(fs.readFileSync(path.join(dir, 'docs', 'readme.txt'), 'utf8'), '# readme');
});

test('pull creates the target directory if it does not exist yet', async (t) => {
  const { server } = startFakeServer({ 'a.txt': 'hello' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = path.join(os.tmpdir(), `syncbox-client-test-missing-${crypto.randomBytes(4).toString('hex')}`);
  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.equal(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'hello');
});

test('pull skips a file whose content already matches the server copy', async (t) => {
  const { server, gets } = startFakeServer({ 'a.txt': 'hello' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, []);
  assert.deepEqual(result.skipped, ['a.txt']);
  assert.deepEqual(gets, []);
});

test('pull re-downloads a file whose local content differs from the server', async (t) => {
  const { server } = startFakeServer({ 'a.txt': 'hello, changed' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['a.txt']);
  assert.equal(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'hello, changed');
});

test('pull downloads only new/changed files, leaving matching ones alone', async (t) => {
  const { server } = startFakeServer({ 'a.txt': 'hello', 'b.txt': 'world' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['b.txt']);
  assert.deepEqual(result.skipped, ['a.txt']);
});

test('pull does not re-download a same-content file even if the local mtime changed', async (t) => {
  const { server, gets } = startFakeServer({ 'a.txt': 'hello' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const filePath = path.join(dir, 'a.txt');
  fs.writeFileSync(filePath, 'hello');
  // Rewrite the exact same bytes - mtime changes, sha256 does not.
  fs.writeFileSync(filePath, 'hello');

  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, []);
  assert.deepEqual(gets, []);
});

test('pull handles nested keys with the same POSIX-key convention as the server, creating subdirectories', async (t) => {
  const { server } = startFakeServer({ 'a/b/c.txt': 'deep' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.equal(fs.readFileSync(path.join(dir, 'a', 'b', 'c.txt'), 'utf8'), 'deep');
});

test('pull does not delete local files that are absent from the server', async (t) => {
  const { server } = startFakeServer({ 'a.txt': 'hello' });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'local-only.txt'), 'keep me');

  await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.equal(fs.readFileSync(path.join(dir, 'local-only.txt'), 'utf8'), 'keep me');
});

test('pull throws a clear error instead of hanging when the server is unreachable', async () => {
  const dir = tempDir();
  await assert.rejects(() => run({ dir, serverUrl: 'http://127.0.0.1:1' }), /connection refused/i);
});

test('pull continues past a server 5xx on one GET, still downloads the rest, and reports the failure', async (t) => {
  const store = new Map([
    ['good.txt', Buffer.from('hello')],
    ['bad.txt', Buffer.from('will fail')],
  ]);

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
    if (match && req.method === 'GET') {
      const key = decodeURIComponent(match[1]);
      if (key === 'bad.txt') {
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end('internal error');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(store.get(key));
      return;
    }

    res.writeHead(404);
    res.end();
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  const result = await run({ dir, serverUrl: `http://127.0.0.1:${port}` });

  assert.deepEqual(result.downloaded, ['good.txt']);
  assert.equal(result.failed.length, 1);
  assert.equal(result.failed[0].key, 'bad.txt');
  assert.match(result.failed[0].error, /status 500/);
  assert.equal(fs.readFileSync(path.join(dir, 'good.txt'), 'utf8'), 'hello');
  assert.equal(fs.existsSync(path.join(dir, 'bad.txt')), false);
});
