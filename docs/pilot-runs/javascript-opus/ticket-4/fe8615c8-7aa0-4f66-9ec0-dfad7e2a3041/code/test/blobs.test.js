// Unit tests of BlobStore for interleavings too narrow to hit reliably
// through HTTP.

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, it, mock } from 'node:test';

import { BlobStore } from '../src/blobs.js';

describe('BlobStore', () => {
  let dataDir;
  let store;

  beforeEach(async () => {
    dataDir = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-store-'));
    store = new BlobStore(dataDir);
  });

  afterEach(async () => {
    mock.restoreAll();
    await fs.rm(dataDir, { recursive: true, force: true });
  });

  it('put() recreates a parent directory pruned by a concurrent delete()', async () => {
    await store.put('dir/old', [Buffer.from('old')]);

    // Make the delete of the directory's last blob land exactly between
    // put()'s mkdir and its rename.
    const rename = fs.rename;
    let interleaved = false;
    mock.method(fs, 'rename', async (from, to) => {
      if (!interleaved) {
        interleaved = true;
        assert.equal(await store.delete('dir/old'), true);
        await assert.rejects(fs.stat(path.join(dataDir, 'blobs', 'dir')), { code: 'ENOENT' });
      }
      return rename(from, to);
    });

    assert.deepEqual(await store.put('dir/new', [Buffer.from('new')]), {
      key: 'dir/new',
      sha256: '11507a0e2f5e69d5dfa40a62a1bd7b6ee57e6bcd85c67c9b8431b36fff21c437',
      size: 3,
    });
    assert.ok(interleaved);
    assert.deepEqual((await store.list()).map((b) => b.key), ['dir/new']);
  });

  it('delete() keeps the blob root itself when it becomes empty', async () => {
    await store.put('only', [Buffer.from('x')]);
    assert.equal(await store.delete('only'), true);
    assert.deepEqual(await fs.readdir(path.join(dataDir, 'blobs')), []);
  });
});
