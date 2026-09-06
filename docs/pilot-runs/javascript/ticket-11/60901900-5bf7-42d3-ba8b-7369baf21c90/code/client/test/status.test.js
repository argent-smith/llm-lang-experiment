'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { status } = require('../src/status');
const { createFakeServer, createHangingServer } = require('../support/fakeServer');

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

test('status fails with a clear message and does not hang when the server accepts the connection but never responds', async () => {
  await withTempDir(async (dir) => {
    const hanging = createHangingServer();
    const baseUrl = await hanging.listen();
    try {
      await assert.rejects(
        () => status({ dir, server: baseUrl, timeoutMs: 200 }),
        /cannot reach server.*timed out/i
      );
    } finally {
      await hanging.close();
    }
  });
});

test('status reports a failed entry when a local file cannot be read, but still reports the rest', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'good.txt'), 'fine');
    await fsp.writeFile(path.join(dir, 'unreadable.txt'), 'will fail to hash');

    const originalCreateReadStream = fs.createReadStream;
    fs.createReadStream = function (filePath, ...args) {
      if (filePath.endsWith('unreadable.txt')) {
        throw new Error('simulated read failure');
      }
      return originalCreateReadStream.call(fs, filePath, ...args);
    };

    try {
      await withFakeServer({}, async ({ baseUrl }) => {
        const result = await status({ dir, server: baseUrl });
        assert.deepEqual(result.toUpload, ['good.txt']);
        assert.equal(result.failed.length, 1);
        assert.equal(result.failed[0].key, 'unreadable.txt');
        assert.match(result.failed[0].error, /simulated read failure/);
      });
    } finally {
      fs.createReadStream = originalCreateReadStream;
    }
  });
});
