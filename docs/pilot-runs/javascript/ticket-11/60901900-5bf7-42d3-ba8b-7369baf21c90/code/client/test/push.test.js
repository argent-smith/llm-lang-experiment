'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { push } = require('../src/push');
const { createFakeServer, createHangingServer } = require('../support/fakeServer');

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

test('push uploads every file when the server has none', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'hello');
    await fsp.mkdir(path.join(dir, 'sub'));
    await fsp.writeFile(path.join(dir, 'sub', 'b.txt'), 'world');

    await withFakeServer({}, async ({ baseUrl, puts }) => {
      const result = await push({ dir, server: baseUrl });

      assert.deepEqual(result.uploaded.sort(), ['a.txt', 'sub/b.txt']);
      assert.deepEqual(result.skipped, []);
      assert.deepEqual(result.failed, []);
      assert.deepEqual(
        puts.map((p) => p.key).sort(),
        ['a.txt', 'sub/b.txt']
      );
    });
  });
});

test('push skips a file whose content already matches the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'unchanged');

    await withFakeServer({ 'a.txt': Buffer.from('unchanged') }, async ({ baseUrl, puts }) => {
      const result = await push({ dir, server: baseUrl });

      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.skipped, ['a.txt']);
      assert.equal(puts.length, 0);
    });
  });
});

test('push re-uploads a file whose content differs from the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'new-content');

    await withFakeServer({ 'a.txt': Buffer.from('old-content') }, async ({ baseUrl, puts, blobs }) => {
      const result = await push({ dir, server: baseUrl });

      assert.deepEqual(result.uploaded, ['a.txt']);
      assert.deepEqual(result.skipped, []);
      assert.equal(puts.length, 1);
      assert.equal(blobs.get('a.txt').buffer.toString(), 'new-content');
    });
  });
});

test('push uses POSIX-style relative paths as keys, even for nested dirs', async () => {
  await withTempDir(async (dir) => {
    await fsp.mkdir(path.join(dir, 'a', 'b'), { recursive: true });
    await fsp.writeFile(path.join(dir, 'a', 'b', 'c.txt'), 'nested');

    await withFakeServer({}, async ({ baseUrl, puts }) => {
      const result = await push({ dir, server: baseUrl });
      assert.deepEqual(result.uploaded, ['a/b/c.txt']);
      assert.equal(puts[0].key, 'a/b/c.txt');
    });
  });
});

test('push mixes uploads and skips correctly across many files', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'same.txt'), 'same');
    await fsp.writeFile(path.join(dir, 'changed.txt'), 'new');
    await fsp.writeFile(path.join(dir, 'new.txt'), 'brand-new');

    await withFakeServer(
      { 'same.txt': Buffer.from('same'), 'changed.txt': Buffer.from('old') },
      async ({ baseUrl }) => {
        const result = await push({ dir, server: baseUrl });
        assert.deepEqual(result.skipped, ['same.txt']);
        assert.deepEqual(result.uploaded.sort(), ['changed.txt', 'new.txt']);
        assert.deepEqual(result.failed, []);
      }
    );
  });
});

test('push rejects a dir argument that does not exist', async () => {
  await assert.rejects(
    () => push({ dir: '/no/such/directory', server: 'http://127.0.0.1:1' }),
    /not a directory/
  );
});

test('push fails fast (does not hang) when the server is unreachable', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'hello');

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
      () => push({ dir, server: `http://127.0.0.1:${port}` }),
      /cannot reach server/
    );
  });
});

test('push fails with a clear message and does not hang when the server accepts the connection but never responds', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'hello');

    const hanging = createHangingServer();
    const baseUrl = await hanging.listen();
    try {
      await assert.rejects(
        () => push({ dir, server: baseUrl, timeoutMs: 200 }),
        /cannot reach server.*timed out/i
      );
    } finally {
      await hanging.close();
    }
  });
});

test('push uploads the remaining files and reports the one the server 5xxs on', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'good.txt'), 'fine');
    await fsp.writeFile(path.join(dir, 'bad.txt'), 'boom');

    await withFakeServer(
      {},
      async ({ baseUrl, puts }) => {
        const result = await push({ dir, server: baseUrl });

        assert.deepEqual(result.uploaded, ['good.txt']);
        assert.equal(result.failed.length, 1);
        assert.equal(result.failed[0].key, 'bad.txt');
        assert.match(result.failed[0].error, /500/);
        assert.deepEqual(puts.map((p) => p.key).sort(), ['good.txt']);
      },
      { failKeys: ['bad.txt'] }
    );
  });
});
