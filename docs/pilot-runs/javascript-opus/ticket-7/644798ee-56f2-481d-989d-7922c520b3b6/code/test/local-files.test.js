import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';

import { listFiles, sha256File } from '../src/local-files.js';

describe('listFiles', () => {
  let tmp;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-local-'));
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  async function makeTree(name, files) {
    const root = path.join(tmp, name);
    for (const [rel, content] of Object.entries(files)) {
      await fs.mkdir(path.dirname(path.join(root, rel)), { recursive: true });
      await fs.writeFile(path.join(root, rel), content);
    }
    await fs.mkdir(root, { recursive: true });
    return root;
  }

  it('lists files recursively, keyed by relative POSIX path, sorted by key', async () => {
    const root = await makeTree('tree', {
      'b.txt': 'b',
      'a/z.txt': 'z',
      'a/deep/er/x.bin': 'x',
      '.hidden': 'h',
      'with space/ünï ?#%.txt': 'u',
    });
    await fs.mkdir(path.join(root, 'empty-dir'));
    const files = await listFiles(root);
    assert.deepEqual(
      files.map((f) => f.key),
      ['.hidden', 'a/deep/er/x.bin', 'a/z.txt', 'b.txt', 'with space/ünï ?#%.txt'],
    );
    for (const { key, path: file } of files) {
      assert.equal(file, path.join(root, ...key.split('/')));
    }
  });

  it('returns nothing for an empty directory', async () => {
    assert.deepEqual(await listFiles(await makeTree('empty', {})), []);
  });

  it('skips symbolic links and special files, reporting each', async () => {
    const root = await makeTree('special', { 'real.txt': 'r', 'sub/inner.txt': 'i' });
    await fs.symlink('real.txt', path.join(root, 'link-to-file'));
    await fs.symlink('sub', path.join(root, 'link-to-dir'));
    await fs.symlink('/etc', path.join(root, 'link-outside'));
    execFileSync('mkfifo', [path.join(root, 'sub', 'pipe')]);

    const skipped = [];
    const files = await listFiles(root, { onSkip: (rel, reason) => skipped.push([rel, reason]) });
    assert.deepEqual(files.map((f) => f.key), ['real.txt', 'sub/inner.txt']);
    assert.deepEqual(skipped.sort(), [
      ['link-outside', 'symbolic link'],
      ['link-to-dir', 'symbolic link'],
      ['link-to-file', 'symbolic link'],
      ['sub/pipe', 'not a regular file'],
    ]);
  });

  it('skips file names that are not valid UTF-8', async () => {
    const root = await makeTree('bad-names', { 'ok.txt': 'ok' });
    const rootBytes = Buffer.from(root);
    await fs.writeFile(Buffer.concat([rootBytes, Buffer.from('/bad-\xff-name', 'latin1')]), 'x');
    await fs.mkdir(Buffer.concat([rootBytes, Buffer.from('/bad-\xfe-dir', 'latin1')]));

    const skipped = [];
    const files = await listFiles(root, { onSkip: (rel, reason) => skipped.push(reason) });
    assert.deepEqual(files.map((f) => f.key), ['ok.txt']);
    assert.deepEqual(skipped, ['file name is not valid UTF-8', 'file name is not valid UTF-8']);
  });

  it('fails for a missing directory or a regular file', async () => {
    await assert.rejects(listFiles(path.join(tmp, 'missing')), { code: 'ENOENT' });
    const file = path.join(tmp, 'plain-file');
    await fs.writeFile(file, 'x');
    await assert.rejects(listFiles(file), { code: 'ENOTDIR' });
  });
});

describe('sha256File', () => {
  it('hashes the file contents', async () => {
    const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-hash-'));
    try {
      const big = Buffer.alloc(3 * 1024 * 1024 + 7, 0xab);
      for (const content of [Buffer.alloc(0), Buffer.from('hello\n'), big]) {
        const file = path.join(tmp, 'f');
        await fs.writeFile(file, content);
        assert.equal(await sha256File(file), createHash('sha256').update(content).digest('hex'));
      }
    } finally {
      await fs.rm(tmp, { recursive: true, force: true });
    }
  });
});
