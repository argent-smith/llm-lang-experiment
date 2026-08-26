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
