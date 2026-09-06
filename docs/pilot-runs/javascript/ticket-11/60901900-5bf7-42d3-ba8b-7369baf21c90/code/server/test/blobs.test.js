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

test('GET /blobs/{key} returns 200 with the exact bytes previously PUT', async () => {
  await withServer(async ({ baseUrl }) => {
    const payload = Buffer.from('hello world');
    await fetch(`${baseUrl}/blobs/greeting`, { method: 'PUT', body: payload });

    const res = await fetch(`${baseUrl}/blobs/greeting`);
    assert.equal(res.status, 200);
    const received = Buffer.from(await res.arrayBuffer());
    assert.ok(received.equals(payload));
  });
});

test('GET /blobs/{key} on a nested multi-segment key returns the stored bytes', async () => {
  await withServer(async ({ baseUrl }) => {
    const payload = Buffer.from('nested content');
    await fetch(`${baseUrl}/blobs/docs/readme.txt`, { method: 'PUT', body: payload });

    const res = await fetch(`${baseUrl}/blobs/docs/readme.txt`);
    assert.equal(res.status, 200);
    const received = Buffer.from(await res.arrayBuffer());
    assert.ok(received.equals(payload));
  });
});

test('GET /blobs/{key} returns 404 when the blob does not exist', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/blobs/does-not-exist`);
    assert.equal(res.status, 404);
  });
});

// Shared across PUT/GET/DELETE: every method that accepts a {key} must
// reject these with 400, not just PUT.
const TRAVERSAL_PATHS = [
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

const MALFORMED_PATHS = ['/blobs/%zz', '/blobs/%ed%a0%80', '/blobs/'];

for (const method of ['PUT', 'GET', 'DELETE']) {
  test(`${method} /blobs/{key} rejects directory traversal and absolute-path keys with 400`, async () => {
    await withServer(async ({ port }) => {
      for (const rawPath of TRAVERSAL_PATHS) {
        const res = await rawRequest(port, method, rawPath, method === 'PUT' ? Buffer.from('x') : undefined);
        assert.equal(res.status, 400, `expected 400 for ${method} ${rawPath}, got ${res.status}`);
      }
    });
  });

  test(`${method} /blobs/{key} rejects malformed percent-encoding and lone surrogates with 400, never 5xx`, async () => {
    await withServer(async ({ port }) => {
      for (const rawPath of MALFORMED_PATHS) {
        const res = await rawRequest(port, method, rawPath, method === 'PUT' ? Buffer.from('x') : undefined);
        assert.ok(res.status < 500, `expected non-5xx for ${method} ${rawPath}, got ${res.status}`);
        assert.equal(res.status, 400, `expected 400 for ${method} ${rawPath}, got ${res.status}`);
      }
    });
  });
}

test('directory traversal attempts never end up written outside the data dir', async () => {
  await withServer(async ({ port, dataDir }) => {
    await rawRequest(port, 'PUT', '/blobs/../outside.txt', Buffer.from('x'));
    await rawRequest(port, 'PUT', '/blobs/%2e%2e/outside.txt', Buffer.from('x'));
    assert.ok(!fs.existsSync(path.join(path.dirname(dataDir), 'outside.txt')));
  });
});

test('DELETE /blobs/{key} removes an existing blob, returns 204, and it disappears from GET and the list', async () => {
  await withServer(async ({ baseUrl }) => {
    const payload = Buffer.from('to be deleted');
    await fetch(`${baseUrl}/blobs/greeting`, { method: 'PUT', body: payload });

    const delRes = await fetch(`${baseUrl}/blobs/greeting`, { method: 'DELETE' });
    assert.equal(delRes.status, 204);
    const delBody = await delRes.arrayBuffer();
    assert.equal(delBody.byteLength, 0);

    const getRes = await fetch(`${baseUrl}/blobs/greeting`);
    assert.equal(getRes.status, 404);

    const listRes = await fetch(`${baseUrl}/blobs`);
    assert.deepEqual(await listRes.json(), []);
  });
});

test('DELETE /blobs/{key} on a nested multi-segment key removes it', async () => {
  await withServer(async ({ baseUrl }) => {
    await fetch(`${baseUrl}/blobs/docs/readme.txt`, { method: 'PUT', body: Buffer.from('nested') });

    const delRes = await fetch(`${baseUrl}/blobs/docs/readme.txt`, { method: 'DELETE' });
    assert.equal(delRes.status, 204);

    const getRes = await fetch(`${baseUrl}/blobs/docs/readme.txt`);
    assert.equal(getRes.status, 404);

    const listRes = await fetch(`${baseUrl}/blobs`);
    assert.deepEqual(await listRes.json(), []);
  });
});

test('DELETE /blobs/{key} returns 404 when the blob does not exist', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/blobs/does-not-exist`, { method: 'DELETE' });
    assert.equal(res.status, 404);
  });
});

test('DELETE /blobs/{key} is not confused by unrelated blobs and leaves them intact', async () => {
  await withServer(async ({ baseUrl }) => {
    await fetch(`${baseUrl}/blobs/keep-me`, { method: 'PUT', body: Buffer.from('keep') });
    await fetch(`${baseUrl}/blobs/delete-me`, { method: 'PUT', body: Buffer.from('gone') });

    const delRes = await fetch(`${baseUrl}/blobs/delete-me`, { method: 'DELETE' });
    assert.equal(delRes.status, 204);

    const getRes = await fetch(`${baseUrl}/blobs/keep-me`);
    assert.equal(getRes.status, 200);
    assert.equal(await getRes.text(), 'keep');

    const listRes = await fetch(`${baseUrl}/blobs`);
    const items = await listRes.json();
    assert.equal(items.length, 1);
    assert.equal(items[0].key, 'keep-me');
  });
});

test('DELETE /blobs/{key} twice in a row: second call returns 404', async () => {
  await withServer(async ({ baseUrl }) => {
    await fetch(`${baseUrl}/blobs/once`, { method: 'PUT', body: Buffer.from('x') });
    const first = await fetch(`${baseUrl}/blobs/once`, { method: 'DELETE' });
    assert.equal(first.status, 204);
    const second = await fetch(`${baseUrl}/blobs/once`, { method: 'DELETE' });
    assert.equal(second.status, 404);
  });
});

const GARBAGE_KEYS = [
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

test('GET /blobs and PUT /blobs/{key} never return a status outside the documented set, for a broad range of garbage keys', async () => {
  await withServer(async ({ port }) => {
    const getRes = await rawRequest(port, 'GET', '/blobs');
    assert.equal(getRes.status, 200);

    for (const key of GARBAGE_KEYS) {
      const res = await rawRequest(port, 'PUT', `/blobs/${key}`, Buffer.from('x'));
      assert.ok(
        res.status === 201 || res.status === 400,
        `PUT /blobs/${key} returned ${res.status}, expected 201 or 400`
      );
    }
  });
});

for (const method of ['GET', 'DELETE']) {
  test(`${method} /blobs/{key} never returns a status outside the documented set, for a broad range of garbage keys`, async () => {
    await withServer(async ({ port }) => {
      for (const key of GARBAGE_KEYS) {
        const res = await rawRequest(port, method, `/blobs/${key}`);
        assert.ok(
          res.status === 400 || res.status === 404,
          `${method} /blobs/${key} returned ${res.status}, expected 400 or 404`
        );
      }
    });
  });
}
