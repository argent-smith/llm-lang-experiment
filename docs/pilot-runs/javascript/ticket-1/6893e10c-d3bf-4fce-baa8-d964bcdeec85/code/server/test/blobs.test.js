'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const { createApp } = require('../src/app');

async function withServer(fn) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-test-'));
  const app = createApp(dataDir);
  await new Promise((resolve) => app.listen(0, '127.0.0.1', resolve));
  const { port } = app.address();
  try {
    await fn({ port, dataDir, baseUrl: `http://127.0.0.1:${port}` });
  } finally {
    await new Promise((resolve) => app.close(resolve));
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
}

// Sends the request with the exact raw path given, bypassing any client-side
// URL normalization (fetch/WHATWG URL silently collapse ".." segments before
// the request is even sent, which would hide the routing bug we're testing).
function rawRequest(port, method, rawPath, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port, method, path: rawPath },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          resolve({ status: res.statusCode, body: Buffer.concat(chunks) });
        });
      }
    );
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

test('GET /healthz returns 200', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/healthz`);
    assert.equal(res.status, 200);
  });
});

test('GET /blobs on an empty store returns 200 with an empty JSON array', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/blobs`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), []);
  });
});

test('PUT /blobs/{key} with an ordinary key returns 201 and correct metadata', async () => {
  await withServer(async ({ baseUrl }) => {
    const payload = Buffer.from('hello world');
    const res = await fetch(`${baseUrl}/blobs/0`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/octet-stream' },
      body: payload,
    });
    assert.equal(res.status, 201);
    const parsed = await res.json();
    assert.equal(parsed.key, '0');
    assert.equal(parsed.size, payload.length);
    assert.equal(parsed.sha256, crypto.createHash('sha256').update(payload).digest('hex'));
  });
});

test('PUT /blobs/{key} with an empty body succeeds as an empty blob', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/blobs/empty`, { method: 'PUT' });
    assert.equal(res.status, 201);
    const parsed = await res.json();
    assert.equal(parsed.size, 0);
    assert.equal(parsed.sha256, crypto.createHash('sha256').update(Buffer.alloc(0)).digest('hex'));
  });
});

test('PUT /blobs/{key} with a multi-segment key stores it nested and lists it back', async () => {
  await withServer(async ({ baseUrl }) => {
    const payload = Buffer.from('nested content');
    const putRes = await fetch(`${baseUrl}/blobs/docs/readme.txt`, { method: 'PUT', body: payload });
    assert.equal(putRes.status, 201);
    const putBody = await putRes.json();
    assert.equal(putBody.key, 'docs/readme.txt');

    const listRes = await fetch(`${baseUrl}/blobs`);
    assert.equal(listRes.status, 200);
    const items = await listRes.json();
    assert.equal(items.length, 1);
    assert.equal(items[0].key, 'docs/readme.txt');
    assert.equal(items[0].size, payload.length);
    assert.equal(items[0].sha256, crypto.createHash('sha256').update(payload).digest('hex'));
    assert.match(items[0].modified_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
  });
});

test('PUT /blobs/{key} rejects directory traversal and absolute-path keys with 400', async () => {
  await withServer(async ({ port }) => {
    const badPaths = [
      '/blobs/..',
      '/blobs/../etc/passwd',
      '/blobs/a/../../etc/passwd',
      '/blobs/%2e%2e/etc/passwd',
      '/blobs/a/..%2f..%2fetc%2fpasswd',
      '/blobs//etc/passwd',
      '/blobs/%2fetc%2fpasswd',
      '/blobs/a//b',
      '/blobs/a/',
    ];
    for (const rawPath of badPaths) {
      const res = await rawRequest(port, 'PUT', rawPath, Buffer.from('x'));
      assert.equal(res.status, 400, `expected 400 for ${rawPath}, got ${res.status}`);
    }
  });
});

test('PUT /blobs/{key} rejects malformed percent-encoding and lone surrogates with 400, never 5xx', async () => {
  await withServer(async ({ port }) => {
    const badPaths = ['/blobs/%zz', '/blobs/%ed%a0%80', '/blobs/'];
    for (const rawPath of badPaths) {
      const res = await rawRequest(port, 'PUT', rawPath, Buffer.from('x'));
      assert.ok(res.status < 500, `expected non-5xx for ${rawPath}, got ${res.status}`);
      assert.equal(res.status, 400, `expected 400 for ${rawPath}, got ${res.status}`);
    }
  });
});

test('directory traversal attempts never end up written outside the data dir', async () => {
  await withServer(async ({ port, dataDir }) => {
    await rawRequest(port, 'PUT', '/blobs/../outside.txt', Buffer.from('x'));
    await rawRequest(port, 'PUT', '/blobs/%2e%2e/outside.txt', Buffer.from('x'));
    assert.ok(!fs.existsSync(path.join(path.dirname(dataDir), 'outside.txt')));
  });
});

test('GET /blobs and PUT /blobs/{key} never return a status outside the documented set, for a broad range of garbage keys', async () => {
  await withServer(async ({ port }) => {
    const getRes = await rawRequest(port, 'GET', '/blobs');
    assert.equal(getRes.status, 200);

    const garbageKeys = [
      '0',
      'a',
      '..',
      '.',
      '...',
      '%2e%2e',
      'a%00b',
      '%00',
      '%E2%98%83',
      encodeURIComponent('日本語'),
      '%ed%a0%80',
      '%',
      '%g0',
      'a'.repeat(300),
      '.hidden',
      'a.',
      '%20',
    ];
    for (const key of garbageKeys) {
      const res = await rawRequest(port, 'PUT', `/blobs/${key}`, Buffer.from('x'));
      assert.ok(
        res.status === 201 || res.status === 400,
        `PUT /blobs/${key} returned ${res.status}, expected 201 or 400`
      );
    }
  });
});
