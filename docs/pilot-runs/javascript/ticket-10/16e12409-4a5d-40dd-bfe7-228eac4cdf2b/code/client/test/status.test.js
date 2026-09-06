'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { status } = require('../src/status');
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

test('status reports a locally-new file as would-upload only', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'brand new');

    await withFakeServer({}, async ({ baseUrl }) => {
      const result = await status({ dir, server: baseUrl });
      assert.deepEqual(result.toUpload, ['local-only.txt']);
      assert.deepEqual(result.toDownload, []);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test('status reports a server-new file as would-download only', async () => {
  await withTempDir(async (dir) => {
    await withFakeServer({ 'server-only.txt': Buffer.from('on server') }, async ({ baseUrl }) => {
      const result = await status({ dir, server: baseUrl });
      assert.deepEqual(result.toUpload, []);
      assert.deepEqual(result.toDownload, ['server-only.txt']);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test('status reports a file that diverged in content as both would-upload and would-download', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'diverged.txt'), 'local version');

    await withFakeServer({ 'diverged.txt': Buffer.from('server version') }, async ({ baseUrl }) => {
      const result = await status({ dir, server: baseUrl });
      assert.deepEqual(result.toUpload, ['diverged.txt']);
      assert.deepEqual(result.toDownload, ['diverged.txt']);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test('status reports a file matching on both sides as unchanged', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'same.txt'), 'identical');

    await withFakeServer({ 'same.txt': Buffer.from('identical') }, async ({ baseUrl }) => {
      const result = await status({ dir, server: baseUrl });
      assert.deepEqual(result.toUpload, []);
      assert.deepEqual(result.toDownload, []);
      assert.deepEqual(result.unchanged, ['same.txt']);
    });
  });
});

test('status mixes all four kinds of entries correctly across many files', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'same.txt'), 'same');
    await fsp.writeFile(path.join(dir, 'diverged.txt'), 'local');
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'only here');

    await withFakeServer(
      {
        'same.txt': Buffer.from('same'),
        'diverged.txt': Buffer.from('server'),
        'server-only.txt': Buffer.from('only there'),
      },
      async ({ baseUrl }) => {
        const result = await status({ dir, server: baseUrl });
        assert.deepEqual(result.toUpload.sort(), ['diverged.txt', 'local-only.txt']);
        assert.deepEqual(result.toDownload.sort(), ['diverged.txt', 'server-only.txt']);
        assert.deepEqual(result.unchanged, ['same.txt']);
      }
    );
  });
});

test('status uses POSIX-style relative paths as keys, even for nested dirs', async () => {
  await withTempDir(async (dir) => {
    await fsp.mkdir(path.join(dir, 'a', 'b'), { recursive: true });
    await fsp.writeFile(path.join(dir, 'a', 'b', 'c.txt'), 'nested');

    await withFakeServer({}, async ({ baseUrl }) => {
      const result = await status({ dir, server: baseUrl });
      assert.deepEqual(result.toUpload, ['a/b/c.txt']);
    });
  });
});

test('status does not perform any PUT or DELETE against the server', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'brand new');
    await fsp.writeFile(path.join(dir, 'diverged.txt'), 'local version');

    await withFakeServer(
      {
        'server-only.txt': Buffer.from('on server'),
        'diverged.txt': Buffer.from('server version'),
      },
      async ({ baseUrl, puts, blobs }) => {
        const sizeBefore = blobs.size;
        await status({ dir, server: baseUrl });
        assert.equal(puts.length, 0);
        assert.equal(blobs.size, sizeBefore);
        assert.equal(blobs.get('diverged.txt').buffer.toString(), 'server version');
      }
    );
  });
});

test('status does not create, modify, or delete any local file', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'same.txt'), 'identical');
    await fsp.writeFile(path.join(dir, 'diverged.txt'), 'local version');

    await withFakeServer(
      {
        'same.txt': Buffer.from('identical'),
        'diverged.txt': Buffer.from('server version'),
        'server-only.txt': Buffer.from('never written locally'),
      },
      async ({ baseUrl }) => {
        await status({ dir, server: baseUrl });

        const entries = (await fsp.readdir(dir)).sort();
        assert.deepEqual(entries, ['diverged.txt', 'same.txt']);
        assert.equal(await fsp.readFile(path.join(dir, 'same.txt'), 'utf8'), 'identical');
        assert.equal(await fsp.readFile(path.join(dir, 'diverged.txt'), 'utf8'), 'local version');
      }
    );
  });
});

test('status rejects a dir argument that does not exist', async () => {
  await assert.rejects(
    () => status({ dir: '/no/such/directory', server: 'http://127.0.0.1:1' }),
    /not a directory/
  );
});

test('status fails fast (does not hang) when the server is unreachable', async () => {
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
      () => status({ dir, server: `http://127.0.0.1:${port}` }),
      /cannot reach server/
    );
  });
});
