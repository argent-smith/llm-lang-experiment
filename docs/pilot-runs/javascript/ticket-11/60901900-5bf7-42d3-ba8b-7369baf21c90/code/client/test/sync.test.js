'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { sync, STATE_FILENAME } = require('../src/sync');
const { createFakeServer, sha256Of, createHangingServer } = require('../support/fakeServer');

async function withTempDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
  try {
    await fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function withFakeServer(initialBlobs, fn, options) {
  const fake = createFakeServer(initialBlobs, options);
  const baseUrl = await fake.listen();
  try {
    await fn({ ...fake, baseUrl });
  } finally {
    await fake.close();
  }
}

function setServerBlob(blobs, key, content, modifiedAt) {
  const buffer = Buffer.from(content);
  blobs.set(key, { buffer, sha256: sha256Of(buffer), modifiedAt: modifiedAt.toISOString() });
}

test('sync uploads a locally-only file to the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'brand new');

    await withFakeServer({}, async ({ baseUrl, blobs }) => {
      const result = await sync({ dir, server: baseUrl });

      assert.deepEqual(result.uploaded, ['local-only.txt']);
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.failed, []);
      assert.equal(blobs.get('local-only.txt').buffer.toString(), 'brand new');
    });
  });
});

test('sync downloads a server-only file to local', async () => {
  await withTempDir(async (dir) => {
    await withFakeServer({ 'server-only.txt': Buffer.from('from server') }, async ({ baseUrl }) => {
      const result = await sync({ dir, server: baseUrl });

      assert.deepEqual(result.downloaded, ['server-only.txt']);
      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.failed, []);
      assert.equal(await fsp.readFile(path.join(dir, 'server-only.txt'), 'utf8'), 'from server');
    });
  });
});

test('sync creates missing subdirectories when downloading a nested server-only key', async () => {
  await withTempDir(async (dir) => {
    await withFakeServer({ 'a/b/c.txt': Buffer.from('nested') }, async ({ baseUrl }) => {
      const result = await sync({ dir, server: baseUrl });
      assert.deepEqual(result.downloaded, ['a/b/c.txt']);
      assert.equal(await fsp.readFile(path.join(dir, 'a', 'b', 'c.txt'), 'utf8'), 'nested');
    });
  });
});

test('sync uploads a file changed only locally since the last sync', async () => {
  await withTempDir(async (dir) => {
    const filePath = path.join(dir, 'a.txt');
    await fsp.writeFile(filePath, 'original');

    await withFakeServer({ 'a.txt': Buffer.from('original') }, async ({ baseUrl, blobs }) => {
      const first = await sync({ dir, server: baseUrl });
      assert.deepEqual(first.unchanged, ['a.txt']);

      await fsp.writeFile(filePath, 'local edit');

      const result = await sync({ dir, server: baseUrl });
      assert.deepEqual(result.uploaded, ['a.txt']);
      assert.deepEqual(result.downloaded, []);
      assert.equal(blobs.get('a.txt').buffer.toString(), 'local edit');
    });
  });
});

test('sync downloads a file changed only on the server since the last sync', async () => {
  await withTempDir(async (dir) => {
    const filePath = path.join(dir, 'a.txt');
    await fsp.writeFile(filePath, 'original');

    await withFakeServer({ 'a.txt': Buffer.from('original') }, async ({ baseUrl, blobs }) => {
      const first = await sync({ dir, server: baseUrl });
      assert.deepEqual(first.unchanged, ['a.txt']);

      setServerBlob(blobs, 'a.txt', 'server edit', new Date());

      const result = await sync({ dir, server: baseUrl });
      assert.deepEqual(result.downloaded, ['a.txt']);
      assert.deepEqual(result.uploaded, []);
      assert.equal(await fsp.readFile(filePath, 'utf8'), 'server edit');
    });
  });
});

test('sync conflict: newer local mtime wins over an older server modified_at', async () => {
  await withTempDir(async (dir) => {
    const filePath = path.join(dir, 'a.txt');
    await fsp.writeFile(filePath, 'original');

    await withFakeServer({ 'a.txt': Buffer.from('original') }, async ({ baseUrl, blobs }) => {
      await sync({ dir, server: baseUrl }); // establish baseline

      const serverTime = new Date('2020-01-01T00:00:00.000Z');
      setServerBlob(blobs, 'a.txt', 'server edit', serverTime);

      await fsp.writeFile(filePath, 'local edit');
      const localTime = new Date('2021-01-01T00:00:00.000Z');
      await fsp.utimes(filePath, localTime, localTime);

      const result = await sync({ dir, server: baseUrl });
      assert.deepEqual(result.uploaded, ['a.txt']);
      assert.deepEqual(result.downloaded, []);
      assert.equal(blobs.get('a.txt').buffer.toString(), 'local edit');
      assert.equal(await fsp.readFile(filePath, 'utf8'), 'local edit');
    });
  });
});

test('sync conflict: newer server modified_at wins over an older local mtime', async () => {
  await withTempDir(async (dir) => {
    const filePath = path.join(dir, 'a.txt');
    await fsp.writeFile(filePath, 'original');

    await withFakeServer({ 'a.txt': Buffer.from('original') }, async ({ baseUrl, blobs }) => {
      await sync({ dir, server: baseUrl }); // establish baseline

      await fsp.writeFile(filePath, 'local edit');
      const localTime = new Date('2020-01-01T00:00:00.000Z');
      await fsp.utimes(filePath, localTime, localTime);

      const serverTime = new Date('2021-01-01T00:00:00.000Z');
      setServerBlob(blobs, 'a.txt', 'server edit', serverTime);

      const result = await sync({ dir, server: baseUrl });
      assert.deepEqual(result.downloaded, ['a.txt']);
      assert.deepEqual(result.uploaded, []);
      assert.equal(await fsp.readFile(filePath, 'utf8'), 'server edit');
      assert.equal(blobs.get('a.txt').buffer.toString(), 'server edit');
    });
  });
});

test('sync conflict with equal mtime/modified_at resolves to the local version', async () => {
  await withTempDir(async (dir) => {
    const filePath = path.join(dir, 'a.txt');
    await fsp.writeFile(filePath, 'original');

    await withFakeServer({ 'a.txt': Buffer.from('original') }, async ({ baseUrl, blobs }) => {
      await sync({ dir, server: baseUrl }); // establish baseline

      const tieTime = new Date('2022-06-15T12:00:00.000Z');
      setServerBlob(blobs, 'a.txt', 'server edit', tieTime);

      await fsp.writeFile(filePath, 'local edit');
      await fsp.utimes(filePath, tieTime, tieTime);

      const result = await sync({ dir, server: baseUrl });
      assert.deepEqual(result.uploaded, ['a.txt']);
      assert.deepEqual(result.downloaded, []);
      assert.equal(blobs.get('a.txt').buffer.toString(), 'local edit');
      assert.equal(await fsp.readFile(filePath, 'utf8'), 'local edit');
    });
  });
});

test('sync does not delete local files absent from the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'keep me');

    await withFakeServer({ 'server-only.txt': Buffer.from('keep me too') }, async ({ baseUrl }) => {
      await sync({ dir, server: baseUrl });
      assert.equal(await fsp.readFile(path.join(dir, 'local-only.txt'), 'utf8'), 'keep me');
    });
  });
});

test('sync does not delete server blobs absent locally', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'keep me');

    await withFakeServer({ 'server-only.txt': Buffer.from('keep me too') }, async ({ baseUrl, blobs }) => {
      await sync({ dir, server: baseUrl });
      assert.equal(blobs.has('server-only.txt'), true);
    });
  });
});

test('sync never transfers its own state file', async () => {
  await withTempDir(async (dir) => {
    await withFakeServer({}, async ({ baseUrl, blobs }) => {
      await sync({ dir, server: baseUrl });
      assert.equal(blobs.has(STATE_FILENAME), false);

      const entries = await fsp.readdir(dir);
      assert.ok(entries.includes(STATE_FILENAME));
    });
  });
});

test('sync is a no-op (reports unchanged) on a second run with no changes', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'stable');

    await withFakeServer({ 'a.txt': Buffer.from('stable') }, async ({ baseUrl }) => {
      await sync({ dir, server: baseUrl });
      const result = await sync({ dir, server: baseUrl });
      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.unchanged, ['a.txt']);
    });
  });
});

test('sync rejects a dir argument that does not exist', async () => {
  await assert.rejects(
    () => sync({ dir: '/no/such/directory', server: 'http://127.0.0.1:1' }),
    /not a directory/
  );
});

test('sync fails fast (does not hang) when the server is unreachable', async () => {
  await withTempDir(async (dir) => {
    // Bind a socket to grab a free, currently-unused port, then close it
    // immediately so nothing is listening there.
    const port = await new Promise((resolve, reject) => {
      const probe = net.createServer();
      probe.listen(0, '127.0.0.1', () => {
        const { port } = probe.address();
        probe.close((err) => (err ? reject(err) : resolve(port)));
      });
      probe.on('error', reject);
    });

    await assert.rejects(
      () => sync({ dir, server: `http://127.0.0.1:${port}` }),
      /cannot reach server/
    );
  });
});

test('sync fails with a clear message and does not hang when the server accepts the connection but never responds', async () => {
  await withTempDir(async (dir) => {
    const hanging = createHangingServer();
    const baseUrl = await hanging.listen();
    try {
      await assert.rejects(
        () => sync({ dir, server: baseUrl, timeoutMs: 200 }),
        /cannot reach server.*timed out/i
      );
    } finally {
      await hanging.close();
    }
  });
});

test('sync uploads the remaining files and reports the one the server 5xxs on for PUT', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'good.txt'), 'fine');
    await fsp.writeFile(path.join(dir, 'bad.txt'), 'boom');

    await withFakeServer(
      {},
      async ({ baseUrl, blobs }) => {
        const result = await sync({ dir, server: baseUrl });

        assert.deepEqual(result.uploaded, ['good.txt']);
        assert.equal(result.failed.length, 1);
        assert.equal(result.failed[0].key, 'bad.txt');
        assert.match(result.failed[0].error, /500/);
        assert.equal(blobs.get('good.txt').buffer.toString(), 'fine');
        assert.equal(blobs.has('bad.txt'), false);
      },
      { failKeys: ['bad.txt'] }
    );
  });
});

test('sync downloads the remaining files and reports the one the server 5xxs on for GET', async () => {
  await withTempDir(async (dir) => {
    await withFakeServer(
      { 'good.txt': Buffer.from('fine'), 'bad.txt': Buffer.from('boom') },
      async ({ baseUrl }) => {
        const result = await sync({ dir, server: baseUrl });

        assert.deepEqual(result.downloaded, ['good.txt']);
        assert.equal(result.failed.length, 1);
        assert.equal(result.failed[0].key, 'bad.txt');
        assert.match(result.failed[0].error, /500/);
        assert.equal(await fsp.readFile(path.join(dir, 'good.txt'), 'utf8'), 'fine');
        await assert.rejects(fsp.readFile(path.join(dir, 'bad.txt'), 'utf8'));
      },
      { failKeys: ['bad.txt'] }
    );
  });
});
