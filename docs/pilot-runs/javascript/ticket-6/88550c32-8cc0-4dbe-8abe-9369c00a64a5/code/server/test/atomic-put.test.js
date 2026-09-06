'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { createApp } = require('../src/app');
const { TMP_DIR_NAME } = require('../src/blobStore');

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

// Reads whatever is currently in the temp-file directory, treating "the
// directory doesn't exist yet" the same as "it's empty".
async function listTmpFiles(dataDir) {
  try {
    return await fsp.readdir(path.join(dataDir, TMP_DIR_NAME));
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
}

// Sends a PUT with a declared Content-Length larger than the bytes actually
// written, then destroys the socket before the body completes — simulating
// a client that disconnects mid-upload.
function abortedPut(port, rawPath, partialBody, declaredLength) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => {
      socket.write(
        `PUT ${rawPath} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: ${declaredLength}\r\nConnection: close\r\n\r\n`
      );
      socket.write(partialBody);
      setTimeout(() => {
        socket.destroy();
        resolve();
      }, 50);
    });
    socket.on('error', () => {
      // A reset from the server tearing down its side is expected once we
      // destroy our end; not a test failure.
    });
  });
}

test('concurrent PUTs to the same key never produce a torn/mixed file: GET always sees one full write', async () => {
  await withServer(async ({ baseUrl }) => {
    const key = 'contested';
    const payloadSize = 2 * 1024 * 1024;
    const N = 8;
    const payloads = Array.from({ length: N }, (_, i) => Buffer.alloc(payloadSize, 0xa0 + i));

    await Promise.all(
      payloads.map((payload) =>
        fetch(`${baseUrl}/blobs/${key}`, { method: 'PUT', body: payload })
      )
    );

    const res = await fetch(`${baseUrl}/blobs/${key}`);
    assert.equal(res.status, 200);
    const received = Buffer.from(await res.arrayBuffer());

    assert.equal(received.length, payloadSize, 'winning write must be full-length, never truncated or concatenated');
    const firstByte = received[0];
    for (let i = 0; i < received.length; i++) {
      assert.equal(received[i], firstByte, `byte ${i} differs from byte 0 — content is mixed across writes`);
    }
    assert.ok(
      payloads.some((p) => p.equals(received)),
      'final content must exactly equal one of the concurrent payloads'
    );
  });
});

test('concurrent PUTs to the same key: reported sha256/size in each response match that response\'s own payload', async () => {
  await withServer(async ({ baseUrl }) => {
    const key = 'contested-metadata';
    const crypto = require('node:crypto');
    const payloads = Array.from({ length: 6 }, (_, i) => Buffer.from(`payload-${i}-${'x'.repeat(1000)}`));

    const results = await Promise.all(
      payloads.map(async (payload) => {
        const res = await fetch(`${baseUrl}/blobs/${key}`, { method: 'PUT', body: payload });
        return { status: res.status, body: await res.json(), payload };
      })
    );

    for (const { status, body, payload } of results) {
      assert.equal(status, 201);
      assert.equal(body.size, payload.length);
      assert.equal(body.sha256, crypto.createHash('sha256').update(payload).digest('hex'));
    }
  });
});

test('concurrent PUTs to different keys do not interfere with each other', async () => {
  await withServer(async ({ baseUrl }) => {
    const N = 12;
    const entries = Array.from({ length: N }, (_, i) => ({
      key: `key-${i}`,
      payload: Buffer.from(`content for key ${i}\n`.repeat(500)),
    }));

    await Promise.all(
      entries.map(({ key, payload }) => fetch(`${baseUrl}/blobs/${key}`, { method: 'PUT', body: payload }))
    );

    for (const { key, payload } of entries) {
      const res = await fetch(`${baseUrl}/blobs/${key}`);
      assert.equal(res.status, 200);
      const received = Buffer.from(await res.arrayBuffer());
      assert.ok(received.equals(payload), `content for ${key} was corrupted or replaced by another key's write`);
    }

    const listRes = await fetch(`${baseUrl}/blobs`);
    const items = await listRes.json();
    assert.equal(items.length, N);
  });
});

test('a burst of concurrent GETs during concurrent overwriting PUTs never observes a torn read', async () => {
  await withServer(async ({ baseUrl }) => {
    const key = 'racing';
    const size = 1024 * 1024;
    const baseline = Buffer.alloc(size, 0x01);
    await fetch(`${baseUrl}/blobs/${key}`, { method: 'PUT', body: baseline });

    const variants = [baseline, ...Array.from({ length: 4 }, (_, i) => Buffer.alloc(size, 0x10 + i))];

    const putters = variants
      .slice(1)
      .map((payload) => fetch(`${baseUrl}/blobs/${key}`, { method: 'PUT', body: payload }));

    const getters = Array.from({ length: 20 }, async () => {
      const res = await fetch(`${baseUrl}/blobs/${key}`);
      const buf = Buffer.from(await res.arrayBuffer());
      return buf;
    });

    const [, getResults] = await Promise.all([Promise.all(putters), Promise.all(getters)]);

    for (const buf of getResults) {
      assert.equal(buf.length, size, 'a GET returned a partial-length body during concurrent writes');
      const firstByte = buf[0];
      const uniform = buf.every((b) => b === firstByte);
      assert.ok(uniform, 'a GET returned bytes mixed from two different writes');
      assert.ok(
        variants.some((v) => v[0] === firstByte),
        'a GET returned content matching none of the known writes'
      );
    }
  });
});

test('no temp files remain on disk after a burst of successful concurrent PUTs', async () => {
  await withServer(async ({ baseUrl, dataDir }) => {
    const entries = Array.from({ length: 10 }, (_, i) => ({
      key: `bulk-${i % 3}`,
      payload: Buffer.from(`bulk payload ${i}`),
    }));
    await Promise.all(
      entries.map(({ key, payload }) => fetch(`${baseUrl}/blobs/${key}`, { method: 'PUT', body: payload }))
    );

    assert.deepEqual(await listTmpFiles(dataDir), []);
  });
});

test('temp files never appear in GET /blobs listing', async () => {
  await withServer(async ({ baseUrl }) => {
    await Promise.all(
      Array.from({ length: 6 }, (_, i) =>
        fetch(`${baseUrl}/blobs/same-key`, { method: 'PUT', body: Buffer.from(`v${i}`) })
      )
    );
    const items = await (await fetch(`${baseUrl}/blobs`)).json();
    assert.equal(items.length, 1);
    assert.ok(!items.some((item) => item.key.startsWith(TMP_DIR_NAME)));
  });
});

test('the temp directory namespace is reserved: PUT/GET/DELETE reject keys under it with 400', async () => {
  await withServer(async ({ baseUrl }) => {
    for (const key of [TMP_DIR_NAME, `${TMP_DIR_NAME}/x`, `${TMP_DIR_NAME}/nested/y`]) {
      const putRes = await fetch(`${baseUrl}/blobs/${key}`, { method: 'PUT', body: Buffer.from('x') });
      assert.equal(putRes.status, 400, `PUT ${key}`);

      const getRes = await fetch(`${baseUrl}/blobs/${key}`);
      assert.equal(getRes.status, 400, `GET ${key}`);

      const delRes = await fetch(`${baseUrl}/blobs/${key}`, { method: 'DELETE' });
      assert.equal(delRes.status, 400, `DELETE ${key}`);
    }
  });
});

test('a connection aborted mid-upload leaves no temp file, no partial blob, and the server stays responsive', async () => {
  await withServer(async ({ port, baseUrl, dataDir }) => {
    await abortedPut(port, '/blobs/never-finished', Buffer.alloc(10), 10 * 1024 * 1024);

    // Give the server a moment to run its error-cleanup path.
    await new Promise((resolve) => setTimeout(resolve, 100));

    assert.deepEqual(await listTmpFiles(dataDir), []);

    const getRes = await fetch(`${baseUrl}/blobs/never-finished`);
    assert.equal(getRes.status, 404);

    const health = await fetch(`${baseUrl}/healthz`);
    assert.equal(health.status, 200);
  });
});

test('an aborted overwrite mid-upload leaves the previous, complete content intact', async () => {
  await withServer(async ({ port, baseUrl, dataDir }) => {
    const original = Buffer.from('original content, fully written');
    await fetch(`${baseUrl}/blobs/overwrite-me`, { method: 'PUT', body: original });

    await abortedPut(port, '/blobs/overwrite-me', Buffer.alloc(10), 10 * 1024 * 1024);
    await new Promise((resolve) => setTimeout(resolve, 100));

    assert.deepEqual(await listTmpFiles(dataDir), []);

    const getRes = await fetch(`${baseUrl}/blobs/overwrite-me`);
    assert.equal(getRes.status, 200);
    const received = Buffer.from(await getRes.arrayBuffer());
    assert.ok(received.equals(original), 'aborted overwrite must not touch the previously stored content');
  });
});
