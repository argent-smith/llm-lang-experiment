'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { createFakeServer } = require('../support/fakeServer');

const execFileAsync = promisify(execFile);
const BIN_PATH = path.join(__dirname, '..', 'bin', 'syncbox');

async function withTempDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-cli-test-'));
  try {
    await fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('syncbox push uploads files via the real CLI entrypoint', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'hello from cli');

    const fake = createFakeServer({});
    const baseUrl = await fake.listen();
    try {
      const { stdout } = await execFileAsync(process.execPath, [
        BIN_PATH,
        'push',
        dir,
        '--server',
        baseUrl,
      ]);

      assert.match(stdout, /uploaded a\.txt/);
      assert.match(stdout, /1 uploaded, 0 unchanged, 0 failed/);
      assert.equal(fake.puts.length, 1);
      assert.equal(fake.puts[0].key, 'a.txt');
      assert.equal(fake.puts[0].body.toString(), 'hello from cli');
    } finally {
      await fake.close();
    }
  });
});

test('syncbox push reads --server from SYNCBOX_SERVER when the flag is absent', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'a.txt'), 'via env');

    const fake = createFakeServer({});
    const baseUrl = await fake.listen();
    try {
      const { stdout } = await execFileAsync(process.execPath, [BIN_PATH, 'push', dir], {
        env: { ...process.env, SYNCBOX_SERVER: baseUrl },
      });
      assert.match(stdout, /uploaded a\.txt/);
    } finally {
      await fake.close();
    }
  });
});

test('syncbox exits non-zero and prints a clear error without --server', async () => {
  await withTempDir(async (dir) => {
    await assert.rejects(execFileAsync(process.execPath, [BIN_PATH, 'push', dir]), (err) => {
      assert.equal(err.code, 1);
      assert.match(err.stderr, /--server is required/);
      return true;
    });
  });
});

test('syncbox sync reports not-implemented instead of crashing', async () => {
  await withTempDir(async (dir) => {
    await assert.rejects(
      execFileAsync(process.execPath, [BIN_PATH, 'sync', dir, '--server', 'http://127.0.0.1:1']),
      (err) => {
        assert.equal(err.code, 1);
        assert.match(err.stderr, /not implemented yet/);
        return true;
      }
    );
  });
});

test('syncbox pull downloads files via the real CLI entrypoint', async () => {
  await withTempDir(async (dir) => {
    const fake = createFakeServer({ 'a.txt': Buffer.from('hello from server') });
    const baseUrl = await fake.listen();
    try {
      const { stdout } = await execFileAsync(process.execPath, [
        BIN_PATH,
        'pull',
        dir,
        '--server',
        baseUrl,
      ]);

      assert.match(stdout, /downloaded a\.txt/);
      assert.match(stdout, /1 downloaded, 0 unchanged, 0 failed/);
      assert.equal(await fsp.readFile(path.join(dir, 'a.txt'), 'utf8'), 'hello from server');
    } finally {
      await fake.close();
    }
  });
});

test('syncbox pull reads --server from SYNCBOX_SERVER when the flag is absent', async () => {
  await withTempDir(async (dir) => {
    const fake = createFakeServer({ 'a.txt': Buffer.from('via env') });
    const baseUrl = await fake.listen();
    try {
      const { stdout } = await execFileAsync(process.execPath, [BIN_PATH, 'pull', dir], {
        env: { ...process.env, SYNCBOX_SERVER: baseUrl },
      });
      assert.match(stdout, /downloaded a\.txt/);
    } finally {
      await fake.close();
    }
  });
});

test('syncbox status reports the diff via the real CLI entrypoint without changing anything', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'new locally');
    await fsp.writeFile(path.join(dir, 'same.txt'), 'same');

    const fake = createFakeServer({
      'server-only.txt': Buffer.from('new on server'),
      'same.txt': Buffer.from('same'),
    });
    const baseUrl = await fake.listen();
    try {
      const { stdout } = await execFileAsync(process.execPath, [
        BIN_PATH,
        'status',
        dir,
        '--server',
        baseUrl,
      ]);

      assert.match(stdout, /would upload local-only\.txt/);
      assert.match(stdout, /would download server-only\.txt/);
      assert.match(stdout, /unchanged same\.txt/);
      assert.match(stdout, /1 would upload, 1 would download, 1 unchanged/);

      // Read-only: server untouched, local dir untouched beyond the two
      // files created by the test setup above.
      assert.equal(fake.puts.length, 0);
      assert.equal(fake.blobs.size, 2);
      assert.deepEqual((await fsp.readdir(dir)).sort(), ['local-only.txt', 'same.txt']);
    } finally {
      await fake.close();
    }
  });
});

test('syncbox status exits 0 even when differences are found', async () => {
  await withTempDir(async (dir) => {
    await fsp.writeFile(path.join(dir, 'local-only.txt'), 'new locally');

    const fake = createFakeServer({});
    const baseUrl = await fake.listen();
    try {
      const { stdout } = await execFileAsync(process.execPath, [
        BIN_PATH,
        'status',
        dir,
        '--server',
        baseUrl,
      ]);
      assert.match(stdout, /would upload local-only\.txt/);
    } finally {
      await fake.close();
    }
  });
});

test('syncbox status reads --server from SYNCBOX_SERVER when the flag is absent', async () => {
  await withTempDir(async (dir) => {
    const fake = createFakeServer({ 'a.txt': Buffer.from('via env') });
    const baseUrl = await fake.listen();
    try {
      const { stdout } = await execFileAsync(process.execPath, [BIN_PATH, 'status', dir], {
        env: { ...process.env, SYNCBOX_SERVER: baseUrl },
      });
      assert.match(stdout, /would download a\.txt/);
    } finally {
      await fake.close();
    }
  });
});
