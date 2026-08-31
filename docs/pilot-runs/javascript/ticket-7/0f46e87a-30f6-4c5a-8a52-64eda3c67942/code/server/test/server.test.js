'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { createServer } = require('../src/server');

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

function get(port, path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    }).on('error', reject);
  });
}

function request(port, method, path, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, method }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

function tempDataDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-test-'));
}

test('GET /healthz returns 200', async (t) => {
  const server = createServer({ dataDir: '/tmp/unused' });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/healthz');
  assert.equal(res.status, 200);
});

test('unknown route returns 404', async (t) => {
  const server = createServer({ dataDir: '/tmp/unused' });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/nope');
  assert.equal(res.status, 404);
});

test('PUT /blobs/{key} stores the blob and returns key/sha256/size', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const content = Buffer.from('hello world');
  const res = await request(port, 'PUT', '/blobs/greeting.txt', content);

  assert.equal(res.status, 201);
  const parsed = JSON.parse(res.body.toString());
  assert.deepEqual(parsed, {
    key: 'greeting.txt',
    sha256: crypto.createHash('sha256').update(content).digest('hex'),
    size: content.length,
  });
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'greeting.txt')), content);
});

test('PUT /blobs/{key} creates nested directories as needed', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const content = Buffer.from('# readme');
  const res = await request(port, 'PUT', '/blobs/docs/readme.txt', content);

  assert.equal(res.status, 201);
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'docs', 'readme.txt')), content);
});

test('PUT /blobs/{key} overwrites an existing blob', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, 'PUT', '/blobs/a.txt', Buffer.from('first'));
  const second = Buffer.from('second, longer content');
  const res = await request(port, 'PUT', '/blobs/a.txt', second);

  assert.equal(res.status, 201);
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'a.txt')), second);
});

test('GET /blobs/{key} returns the stored bytes', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const content = Buffer.from([0, 1, 2, 255, 254]);
  await request(port, 'PUT', '/blobs/binary.dat', content);

  const res = await get(port, '/blobs/binary.dat');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, content);
});

test('GET /blobs/{key} for a nested key returns the stored bytes', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const content = Buffer.from('nested content');
  await request(port, 'PUT', '/blobs/docs/readme.txt', content);

  const res = await get(port, '/blobs/docs/readme.txt');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, content);
});

test('GET /blobs/{key} returns 404 when the blob does not exist', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/blobs/missing.txt');
  assert.equal(res.status, 404);
});

test('GET /blobs returns an empty array for an empty store', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/blobs');
  assert.equal(res.status, 200);
  assert.deepEqual(JSON.parse(res.body.toString()), []);
});

test('GET /blobs lists stored blobs with metadata', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const content = Buffer.from('hello world');
  await request(port, 'PUT', '/blobs/greeting.txt', content);

  const res = await get(port, '/blobs');
  assert.equal(res.status, 200);
  const parsed = JSON.parse(res.body.toString());
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].key, 'greeting.txt');
  assert.equal(parsed[0].size, content.length);
  assert.equal(parsed[0].sha256, crypto.createHash('sha256').update(content).digest('hex'));
  assert.match(parsed[0].modified_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
});

test('GET /blobs includes nested keys as POSIX paths', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, 'PUT', '/blobs/docs/readme.txt', Buffer.from('# readme'));
  await request(port, 'PUT', '/blobs/top.txt', Buffer.from('top level'));

  const res = await get(port, '/blobs');
  assert.equal(res.status, 200);
  const parsed = JSON.parse(res.body.toString());
  const keys = parsed.map((b) => b.key).sort();
  assert.deepEqual(keys, ['docs/readme.txt', 'top.txt']);
});

test('DELETE /blobs/{key} removes an existing blob and returns 204', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, 'PUT', '/blobs/greeting.txt', Buffer.from('hello world'));

  const res = await request(port, 'DELETE', '/blobs/greeting.txt');
  assert.equal(res.status, 204);
  assert.equal(res.body.length, 0);
  assert.equal(fs.existsSync(path.join(dataDir, 'greeting.txt')), false);
});

test('DELETE /blobs/{key} returns 404 when the blob does not exist', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'DELETE', '/blobs/missing.txt');
  assert.equal(res.status, 404);
});

test('DELETE /blobs/{key} for a nested key removes the file', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, 'PUT', '/blobs/docs/readme.txt', Buffer.from('# readme'));

  const res = await request(port, 'DELETE', '/blobs/docs/readme.txt');
  assert.equal(res.status, 204);
  assert.equal(fs.existsSync(path.join(dataDir, 'docs', 'readme.txt')), false);
});

test('deleted blob disappears from GET /blobs and GET /blobs/{key} returns 404', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, 'PUT', '/blobs/a.txt', Buffer.from('one'));
  await request(port, 'PUT', '/blobs/b.txt', Buffer.from('two'));

  await request(port, 'DELETE', '/blobs/a.txt');

  const getRes = await get(port, '/blobs/a.txt');
  assert.equal(getRes.status, 404);

  const listRes = await get(port, '/blobs');
  const parsed = JSON.parse(listRes.body.toString());
  assert.deepEqual(parsed.map((b) => b.key), ['b.txt']);
});

test('PUT /blobs/{key} rejects a ".." key with 400 and does not touch the filesystem', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'PUT', '/blobs/../escaped.txt', Buffer.from('evil'));
  assert.equal(res.status, 400);
  assert.equal(fs.existsSync(path.join(path.dirname(dataDir), 'escaped.txt')), false);
});

test('PUT /blobs/{key} rejects a percent-encoded ".." key with 400', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'PUT', '/blobs/%2e%2e%2fescaped.txt', Buffer.from('evil'));
  assert.equal(res.status, 400);
  assert.equal(fs.existsSync(path.join(path.dirname(dataDir), 'escaped.txt')), false);
});

test('PUT /blobs/{key} rejects a middle ".." segment with 400', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'PUT', '/blobs/docs/../../escaped.txt', Buffer.from('evil'));
  assert.equal(res.status, 400);
});

test('PUT /blobs/{key} rejects an absolute path key with 400', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'PUT', '/blobs/%2Fetc%2Fpasswd', Buffer.from('evil'));
  assert.equal(res.status, 400);
});

test('PUT /blobs/{key} rejects malformed percent-encoding with 400, not a crash', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'PUT', '/blobs/%E2%82', Buffer.from('evil'));
  assert.equal(res.status, 400);

  const health = await get(port, '/healthz');
  assert.equal(health.status, 200);
});

test('PUT /blobs/{key} rejects a NUL byte in the key with 400, not a crash', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'PUT', '/blobs/foo%00bar', Buffer.from('evil'));
  assert.equal(res.status, 400);

  const health = await get(port, '/healthz');
  assert.equal(health.status, 200);
});

test('PUT /blobs/{key} allows a key that merely contains ".." as a substring', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const content = Buffer.from('not a traversal');
  const res = await request(port, 'PUT', '/blobs/file..txt', content);
  assert.equal(res.status, 201);
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'file..txt')), content);
});

test('GET /blobs/{key} rejects a ".." key with 400 instead of 404 or 500', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/blobs/../etc/passwd');
  assert.equal(res.status, 400);
});

test('GET /blobs/{key} rejects an absolute path key with 400', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/blobs/%2Fetc%2Fpasswd');
  assert.equal(res.status, 400);
});

test('DELETE /blobs/{key} rejects a ".." key with 400 and does not delete anything', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, 'PUT', '/blobs/keep.txt', Buffer.from('keep me'));

  const res = await request(port, 'DELETE', '/blobs/../keep.txt');
  assert.equal(res.status, 400);
  assert.equal(fs.existsSync(path.join(dataDir, 'keep.txt')), true);
});

test('DELETE /blobs/{key} rejects an absolute path key with 400', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await request(port, 'DELETE', '/blobs/%2Fetc%2Fpasswd');
  assert.equal(res.status, 400);
});

test('GET /blobs reflects overwrites (one entry per key, latest content)', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  await request(port, 'PUT', '/blobs/a.txt', Buffer.from('first'));
  const second = Buffer.from('second, longer content');
  await request(port, 'PUT', '/blobs/a.txt', second);

  const res = await get(port, '/blobs');
  const parsed = JSON.parse(res.body.toString());
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].size, second.length);
  assert.equal(parsed[0].sha256, crypto.createHash('sha256').update(second).digest('hex'));
});
