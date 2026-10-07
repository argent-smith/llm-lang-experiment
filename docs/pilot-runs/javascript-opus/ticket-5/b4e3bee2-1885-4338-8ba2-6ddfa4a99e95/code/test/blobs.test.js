// Unit tests of BlobStore for interleavings too narrow to hit reliably
// through HTTP.

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, it, mock } from 'node:test';

import { BlobStore, InvalidKeyError } from '../src/blobs.js';

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

describe('BlobStore containment', () => {
  let tmp;
  let dataDir;
  let outside;
  let store;

  beforeEach(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-contain-'));
    dataDir = path.join(tmp, 'data');
    outside = path.join(tmp, 'outside');
    await fs.mkdir(outside);
    await fs.writeFile(path.join(outside, 'secret'), 'top secret');
    store = new BlobStore(dataDir);
  });

  afterEach(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  // Keys parseKey() rejects, handed straight to the store: the store must
  // refuse them on its own rather than trust its caller.
  const escapingKeys = ['..', '../outside/secret', 'a/../../outside/secret', 'a/..', './a', '.', '/etc/passwd', 'a//b', 'a/', '', 'a\0b'];

  it('pathOf() maps a key to a path strictly inside the blob root', () => {
    assert.equal(store.pathOf('docs/readme.txt'), path.join(dataDir, 'blobs', 'docs', 'readme.txt'));
    assert.equal(store.pathOf('..a/b..'), path.join(dataDir, 'blobs', '..a', 'b..'));
    assert.equal(store.pathOf('back\\..\\slash'), path.join(dataDir, 'blobs', 'back\\..\\slash'));
  });

  for (const key of escapingKeys) {
    it(`pathOf(), put(), open() and delete() reject ${JSON.stringify(key)} on their own`, async () => {
      assert.throws(() => store.pathOf(key), InvalidKeyError);
      await assert.rejects(store.put(key, [Buffer.from('escaped')]), InvalidKeyError);
      await assert.rejects(store.open(key), InvalidKeyError);
      await assert.rejects(store.delete(key), InvalidKeyError);
    });
  }

  it('rejected keys leave nothing behind and touch nothing outside', async () => {
    for (const key of escapingKeys) await store.put(key, [Buffer.from('escaped')]).catch(() => {});
    for (const name of await fs.readdir(tmp)) assert.ok(['data', 'outside'].includes(name), name);
    assert.deepEqual(await fs.readdir(outside), ['secret']);
    assert.deepEqual(await fs.readdir(path.join(dataDir, 'tmp')).catch(() => []), []);
    assert.deepEqual(await store.list(), []);
  });

  it('a relative data dir is resolved, so the containment check still holds', async () => {
    const rel = new BlobStore(path.relative(process.cwd(), dataDir));
    assert.equal(rel.root, path.join(dataDir, 'blobs'));
    assert.throws(() => rel.pathOf('../outside/secret'), InvalidKeyError);
  });

  describe('with a symlink to a directory outside the root', () => {
    beforeEach(async () => {
      await fs.mkdir(path.join(dataDir, 'blobs', 'nested'), { recursive: true });
      await fs.symlink(outside, path.join(dataDir, 'blobs', 'link'));
      await fs.symlink(outside, path.join(dataDir, 'blobs', 'nested', 'link'));
    });

    for (const prefix of ['link', 'nested/link']) {
      it(`open() does not read through ${prefix}/`, async () => {
        await assert.rejects(store.open(`${prefix}/secret`), InvalidKeyError);
      });

      it(`put() does not write or create directories through ${prefix}/`, async () => {
        await assert.rejects(store.put(`${prefix}/secret`, [Buffer.from('pwned')]), InvalidKeyError);
        await assert.rejects(store.put(`${prefix}/new/dir/file`, [Buffer.from('pwned')]), InvalidKeyError);
        assert.deepEqual(await fs.readdir(outside), ['secret']);
        assert.equal(await fs.readFile(path.join(outside, 'secret'), 'utf8'), 'top secret');
        assert.deepEqual(await fs.readdir(path.join(dataDir, 'tmp')), []);
      });

      it(`delete() does not remove anything through ${prefix}/`, async () => {
        await assert.rejects(store.delete(`${prefix}/secret`), InvalidKeyError);
        assert.deepEqual(await fs.readdir(outside), ['secret']);
      });
    }

    it('a symlink as the key itself is not a blob: open() and delete() find nothing', async () => {
      await fs.symlink(path.join(outside, 'secret'), path.join(dataDir, 'blobs', 'file-link'));
      assert.equal(await store.open('file-link'), null);
      assert.equal(await store.delete('file-link'), false);
      assert.equal((await fs.lstat(path.join(dataDir, 'blobs', 'file-link'))).isSymbolicLink(), true);
      assert.equal(await fs.readFile(path.join(outside, 'secret'), 'utf8'), 'top secret');
    });

    it('put() over a file symlink replaces the link, not the file it points to', async () => {
      await fs.symlink(path.join(outside, 'secret'), path.join(dataDir, 'blobs', 'file-link'));
      await store.put('file-link', [Buffer.from('mine')]);
      assert.equal(await fs.readFile(path.join(outside, 'secret'), 'utf8'), 'top secret');
      assert.equal((await fs.lstat(path.join(dataDir, 'blobs', 'file-link'))).isFile(), true);
    });

    it('a symlink loop is rejected rather than crashing', async () => {
      await fs.symlink('loop', path.join(dataDir, 'blobs', 'loop'));
      await assert.rejects(store.open('loop/x'), InvalidKeyError);
      await assert.rejects(store.put('loop/x', [Buffer.from('x')]), InvalidKeyError);
      await assert.rejects(store.delete('loop/x'), InvalidKeyError);
    });

    it('ordinary keys keep working next to the symlinks', async () => {
      await store.put('nested/real', [Buffer.from('ok')]);
      const blob = await store.open('nested/real');
      assert.equal(blob.size, 2);
      await blob.fh.close();
      assert.equal(await store.delete('nested/real'), true);
    });
  });

  it('a data dir that is itself reached through a symlink still works', async () => {
    const real = path.join(tmp, 'real-data');
    await fs.mkdir(real);
    await fs.symlink(real, path.join(tmp, 'linked-data'));
    const linked = new BlobStore(path.join(tmp, 'linked-data'));
    await linked.put('a/b', [Buffer.from('via link')]);
    const blob = await linked.open('a/b');
    assert.equal(blob.size, 8);
    await blob.fh.close();
    assert.equal(await linked.delete('a/b'), true);
  });
});
