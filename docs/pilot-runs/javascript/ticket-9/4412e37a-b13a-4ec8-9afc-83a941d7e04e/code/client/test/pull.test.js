'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { pull } = require('../src/pull');
const { createFakeServer } = require('../support/fakeServer');

async function withTempDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
  try {
    await fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function withFakeServer(initialBlobs, fn) {
  const fake = createFakeServer(initialBlobs);
  const baseUrl = await fake.listen();
  try {
    await fn({ ...fake, baseUrl });
  } finally {
    await fake.close();
  }
}

test('pull downloads every file when the local dir has none', async () => {
  await withTempDir(async (dir) => {
    await withFakeServer(
      { 'a.txt': Buffer.from('hello'), 'sub/b.txt': Buffer.from('world') },
      async ({ baseUrl }) => {
        const result = await pull({ dir, server: baseUrl });

        assert.deepEqual(result.downloaded.sort(), ['a.txt', 'sub/b.txt']);
        assert.deepEqual(result.skipped, []);
        assert.deepEqual(result.failed, []);
        assert.equal(await fsp.readFile(path.join(dir, 'a.txt'), 'utf8'), 'hello');
        assert.equal(await fsp.readFile(path.join(dir, 'sub', 'b.txt'), 'utf8'), 'world');
      }
    );
  });
});

test('pull skips a file whose content already matches the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'unchanged');

    await withFakeServer({ 'a.txt': Buffer.from('unchanged') }, async ({ baseUrl }) => {
      const result = await pull({ dir, server: baseUrl });

      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.skipped, ['a.txt']);
      assert.equal(await fsp.readFile(path.join(dir, 'a.txt'), 'utf8'), 'unchanged');
    });
  });
});

test('pull re-downloads a file whose content differs from the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'old-content');

    await withFakeServer({ 'a.txt': Buffer.from('new-content') }, async ({ baseUrl }) => {
      const result = await pull({ dir, server: baseUrl });

      assert.deepEqual(result.downloaded, ['a.txt']);
      assert.deepEqual(result.skipped, []);
      assert.equal(await fsp.readFile(path.join(dir, 'a.txt'), 'utf8'), 'new-content');
    });
  });
});

test('pull creates missing subdirectories for nested keys', async () => {
  await withTempDir(async (dir) => {
    await withFakeServer({ 'a/b/c.txt': Buffer.from('nested') }, async ({ baseUrl }) => {
      const result = await pull({ dir, server: baseUrl });
      assert.deepEqual(result.downloaded, ['a/b/c.txt']);
      assert.equal(await fsp.readFile(path.join(dir, 'a', 'b', 'c.txt'), 'utf8'), 'nested');
    });
  });
});

test('pull mixes downloads and skips correctly across many files', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'same.txt'), 'same');
    await fsp.writeFile(path.join(dir, 'changed.txt'), 'old');

    await withFakeServer(
      {
        'same.txt': Buffer.from('same'),
        'changed.txt': Buffer.from('new'),
        'new.txt': Buffer.from('brand-new'),
      },
      async ({ baseUrl }) => {
        const result = await pull({ dir, server: baseUrl });
        assert.deepEqual(result.skipped, ['same.txt']);
        assert.deepEqual(result.downloaded.sort(), ['changed.txt', 'new.txt']);
        assert.deepEqual(result.failed, []);
      }
    );
  });
});

test('pull does not delete local files absent from the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'keep me');

    await withFakeServer({ 'a.txt': Buffer.from('hello') }, async ({ baseUrl }) => {
      await pull({ dir, server: baseUrl });
      assert.equal(await fsp.readFile(path.join(dir, 'local-only.txt'), 'utf8'), 'keep me');
    });
  });
});

test('pull rejects a dir argument that does not exist', async () => {
  await assert.rejects(
    () => pull({ dir: '/no/such/directory', server: 'http://127.0.0.1:1' }),
    /not a directory/
  );
});

test('pull fails fast (does not hang) when the server is unreachable', async () => {
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
      () => pull({ dir, server: `http://127.0.0.1:${port}` }),
      /cannot reach server/
    );
  });
});
