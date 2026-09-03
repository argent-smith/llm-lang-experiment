'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { createServer } = require('../src/server');
const { isTempFileName } = require('../src/atomic-write');

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

function get(port, urlPath) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: urlPath }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    }).on('error', reject);
  });
}

function request(port, method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: urlPath, method }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

// Starts a PUT whose body is fed manually via req.write(), so the test can
// control exactly how much has been sent at any point (chunked transfer
// encoding, since no Content-Length is given up front).
function startStreamingPut(port, urlPath) {
  const req = http.request({ host: '127.0.0.1', port, path: urlPath, method: 'PUT' });
  const settled = new Promise((resolve, reject) => {
    req.on('response', (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
  });
  return { req, settled };
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 20));
}

function tempDataDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-test-'));
}

test('a GET running while a PUT is in flight sees the fully old content, never a partial write', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const oldContent = Buffer.from('this is the original, fully-written blob content');
  await request(port, 'PUT', '/blobs/a.txt', oldContent);

  const newContent = Buffer.alloc(200_000, 'X');
  const { req, settled } = startStreamingPut(port, '/blobs/a.txt');
  req.write(newContent.subarray(0, 100_000));
  await tick();

  const midWrite = await get(port, '/blobs/a.txt');
  assert.equal(midWrite.status, 200);
  assert.deepEqual(midWrite.body, oldContent);

  req.write(newContent.subarray(100_000));
  req.end();
  const putResult = await settled;
  assert.equal(putResult.status, 201);

  const afterWrite = await get(port, '/blobs/a.txt');
  assert.deepEqual(afterWrite.body, newContent);
});

test('GET /blobs does not list temp files while a PUT is in flight', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const { req, settled } = startStreamingPut(port, '/blobs/a.txt');
  req.write(Buffer.from('partial content, not done yet'));
  await tick();

  const onDiskEntries = fs.readdirSync(dataDir);
  assert.equal(onDiskEntries.length, 1);
  assert.ok(isTempFileName(onDiskEntries[0]), `expected a temp file, got ${onDiskEntries[0]}`);

  const listRes = await get(port, '/blobs');
  assert.equal(listRes.status, 200);
  assert.deepEqual(JSON.parse(listRes.body.toString()), []);

  req.end();
  await settled;

  const finalList = await get(port, '/blobs');
  assert.deepEqual(JSON.parse(finalList.body.toString()).map((b) => b.key), ['a.txt']);
});

test('concurrent PUTs to the same key never produce corrupted content, and no temp files remain', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const contentA = Buffer.alloc(100_000, 'A');
  const contentB = Buffer.alloc(100_000, 'B');

  const [resA, resB] = await Promise.all([
    request(port, 'PUT', '/blobs/a.txt', contentA),
    request(port, 'PUT', '/blobs/a.txt', contentB),
  ]);
  assert.equal(resA.status, 201);
  assert.equal(resB.status, 201);

  const stored = fs.readFileSync(path.join(dataDir, 'a.txt'));
  assert.ok(stored.equals(contentA) || stored.equals(contentB));

  const finalGet = await get(port, '/blobs/a.txt');
  assert.deepEqual(finalGet.body, stored);

  assert.deepEqual(fs.readdirSync(dataDir), ['a.txt']);
});

test('concurrent PUTs to different keys both succeed with correct content', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const contentA = Buffer.alloc(80_000, 'A');
  const contentB = Buffer.alloc(80_000, 'B');

  const [resA, resB] = await Promise.all([
    request(port, 'PUT', '/blobs/a.txt', contentA),
    request(port, 'PUT', '/blobs/b.txt', contentB),
  ]);

  assert.equal(resA.status, 201);
  assert.equal(resB.status, 201);
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'a.txt')), contentA);
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'b.txt')), contentB);
  assert.deepEqual(fs.readdirSync(dataDir).sort(), ['a.txt', 'b.txt']);
});

test('a client aborting mid-upload leaves no temp file and does not create the blob', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const { req, settled } = startStreamingPut(port, '/blobs/a.txt');
  req.write(Buffer.from('this upload will be cut short'));
  await tick();
  req.destroy();
  await settled.catch(() => {});

  for (let i = 0; i < 25 && fs.readdirSync(dataDir).length > 0; i++) {
    await tick();
  }

  assert.deepEqual(fs.readdirSync(dataDir), []);
  assert.equal(fs.existsSync(path.join(dataDir, 'a.txt')), false);

  const health = await get(port, '/healthz');
  assert.equal(health.status, 200);
});

test('an aborted PUT does not clobber a pre-existing blob at the same key', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const oldContent = Buffer.from('the original content that must survive');
  await request(port, 'PUT', '/blobs/a.txt', oldContent);

  const { req, settled } = startStreamingPut(port, '/blobs/a.txt');
  req.write(Buffer.from('replacement that never finishes'));
  await tick();
  req.destroy();
  await settled.catch(() => {});
  await tick();

  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'a.txt')), oldContent);

  const health = await get(port, '/healthz');
  assert.equal(health.status, 200);
});

test('the server keeps handling requests normally after an aborted upload', async (t) => {
  const dataDir = tempDataDir();
  const server = createServer({ dataDir });
  const port = await listen(server);
  t.after(() => server.close());

  const { req, settled } = startStreamingPut(port, '/blobs/aborted.txt');
  req.write(Buffer.from('never finishes'));
  await tick();
  req.destroy();
  await settled.catch(() => {});
  await tick();

  const content = Buffer.from('a completely unrelated, successful upload');
  const res = await request(port, 'PUT', '/blobs/fine.txt', content);
  assert.equal(res.status, 201);
  const parsed = JSON.parse(res.body.toString());
  assert.equal(parsed.sha256, crypto.createHash('sha256').update(content).digest('hex'));
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'fine.txt')), content);
});
