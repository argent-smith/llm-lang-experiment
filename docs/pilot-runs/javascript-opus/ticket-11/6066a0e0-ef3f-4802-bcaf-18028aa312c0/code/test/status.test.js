// status() against a real Syncbox server running in-process on loopback, and
// formatStatus() on its own.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';

import { RequestError, SyncboxClient } from '../src/client.js';
import { createServer } from '../src/server.js';
import { formatStatus, status } from '../src/status.js';

const sha256 = (data) => createHash('sha256').update(data).digest('hex');

async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}

async function writeTree(root, files) {
  for (const [rel, content] of Object.entries(files)) {
    await fs.mkdir(path.dirname(path.join(root, rel)), { recursive: true });
    await fs.writeFile(path.join(root, rel), content);
  }
}

/**
 * Everything under `root` that a change would show up in: each entry's type,
 * contents, mode, inode and mtime.
 */
async function snapshot(root) {
  const out = {};
  for (const entry of await fs.readdir(root, { recursive: true, withFileTypes: true })) {
    const full = path.join(entry.path, entry.name);
    const rel = path.relative(root, full).split(path.sep).join('/');
    const stat = await fs.lstat(full);
    const meta = `mode=${stat.mode} ino=${stat.ino} mtime=${stat.mtimeMs}`;
    if (entry.isSymbolicLink()) {
      out[rel] = `<symlink ${await fs.readlink(full)}> ${meta}`;
    } else if (entry.isDirectory()) {
      out[rel] = `<dir> ${meta}`;
    } else {
      out[rel] = `${sha256(await fs.readFile(full))} ${meta}`;
    }
  }
  return out;
}

const keys = (entries) => entries.map(({ key, reason }) => `${reason} ${key}`);

describe('status', () => {
  let tmp;
  let server;
  let baseUrl;
  let client;
  let dir;
  let dataDir;
  let requests;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-status-'));
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  let serial = 0;

  beforeEach(async () => {
    const name = `case-${++serial}`;
    dir = path.join(tmp, name, 'local');
    dataDir = path.join(tmp, name, 'data');
    await fs.mkdir(dir, { recursive: true });
    server = createServer({ dataDir });
    // Every request the server sees, as "METHOD path".
    requests = [];
    server.on('request', (req) => requests.push(`${req.method} ${req.url}`));
    baseUrl = await listen(server);
    client = new SyncboxClient(new URL(baseUrl));
  });

  afterEach(async () => {
    await close(server);
  });

  async function putBlobs(blobs) {
    for (const [key, content] of Object.entries(blobs)) {
      const url = `${baseUrl}/blobs/${key.split('/').map(encodeURIComponent).join('/')}`;
      const res = await fetch(url, { method: 'PUT', body: content });
      assert.equal(res.status, 201, key);
    }
    requests.length = 0;
  }

  it('lists a file that exists only locally as an upload', async () => {
    await writeTree(dir, { 'docs/local-only.txt': 'local' });
    const result = await status({ dir, client });
    assert.deepEqual(keys(result.upload), ['new docs/local-only.txt']);
    assert.deepEqual(result.download, []);
    assert.deepEqual(result.upToDate, []);
  });

  it('lists a blob that exists only on the server as a download', async () => {
    await putBlobs({ 'docs/server-only.txt': 'remote' });
    const result = await status({ dir, client });
    assert.deepEqual(result.upload, []);
    assert.deepEqual(keys(result.download), ['new docs/server-only.txt']);
    assert.deepEqual(result.upToDate, []);
  });

  it('lists a file whose contents differ in both directions', async () => {
    await putBlobs({ 'f.txt': 'aaaa' });
    // Same size, different bytes: compared by SHA-256.
    await writeTree(dir, { 'f.txt': 'bbbb' });
    const result = await status({ dir, client });
    assert.deepEqual(keys(result.upload), ['differs f.txt']);
    assert.deepEqual(keys(result.download), ['differs f.txt']);
    assert.deepEqual(result.upToDate, []);
  });

  it('sorts a mixed tree into uploads, downloads and up-to-date files', async () => {
    await putBlobs({ 'same.txt': 'same', 'sub/same.txt': 's', 'changed.txt': 'server', 'remote/new.txt': 'r', 'z.txt': 'z' });
    await writeTree(dir, { 'same.txt': 'same', 'sub/same.txt': 's', 'changed.txt': 'local', 'a/local.txt': 'l', 'with space/ü ?#%.txt': 'odd' });
    const result = await status({ dir, client });
    assert.deepEqual(keys(result.upload), ['new a/local.txt', 'differs changed.txt', 'new with space/ü ?#%.txt']);
    assert.deepEqual(keys(result.download), ['differs changed.txt', 'new remote/new.txt', 'new z.txt']);
    assert.deepEqual(result.upToDate, ['same.txt', 'sub/same.txt']);
  });

  it('finds nothing to do when both sides hold the same files', async () => {
    await putBlobs({ 'a.txt': 'a', 'sub/b.txt': 'b' });
    await writeTree(dir, { 'a.txt': 'a', 'sub/b.txt': 'b' });
    assert.deepEqual(await status({ dir, client }), { upload: [], download: [], upToDate: ['a.txt', 'sub/b.txt'], failed: [] });
  });

  it('finds nothing to do when both sides are empty', async () => {
    assert.deepEqual(await status({ dir, client }), { upload: [], download: [], upToDate: [], failed: [] });
  });

  it('changes nothing on the server or in the directory', async () => {
    await putBlobs({ 'same.txt': 'same', 'changed.txt': 'server', 'remote.txt': 'r', 'nested/deep/remote.bin': Buffer.from([0, 1, 2]) });
    await writeTree(dir, { 'same.txt': 'same', 'changed.txt': 'local', 'local.txt': 'l', 'nested/local.txt': 'n' });
    await fs.symlink('same.txt', path.join(dir, 'link'));
    const localBefore = await snapshot(dir);
    const serverBefore = await snapshot(dataDir);
    const listingBefore = await (await fetch(`${baseUrl}/blobs`)).json();
    requests.length = 0;

    const result = await status({ dir, client });
    assert.equal(result.upload.length, 3);
    assert.equal(result.download.length, 3);

    // Only the listing was requested: no PUT, no DELETE, not even a download.
    assert.deepEqual(requests, ['GET /blobs']);
    assert.deepEqual(await snapshot(dir), localBefore);
    assert.deepEqual(await snapshot(dataDir), serverBefore);
    assert.deepEqual(await (await fetch(`${baseUrl}/blobs`)).json(), listingBefore);
  });

  it('works on a read-only directory', { skip: process.getuid?.() === 0 && 'root ignores permissions' }, async () => {
    await putBlobs({ 'remote.txt': 'r' });
    await writeTree(dir, { 'sub/local.txt': 'l' });
    await fs.chmod(path.join(dir, 'sub'), 0o555);
    await fs.chmod(dir, 0o555);
    try {
      const result = await status({ dir, client });
      assert.deepEqual(keys(result.upload), ['new sub/local.txt']);
      assert.deepEqual(keys(result.download), ['new remote.txt']);
    } finally {
      await fs.chmod(dir, 0o755);
      await fs.chmod(path.join(dir, 'sub'), 0o755);
    }
  });

  it('leaves out what push or pull would skip, reporting it', async () => {
    const outside = path.join(dir, '..', 'outside');
    await writeTree(outside, { 'target.txt': 'outside' });
    await fs.symlink(outside, path.join(dir, 'linked-dir'));
    await fs.symlink(path.join(outside, 'target.txt'), path.join(dir, 'linked-file'));
    await putBlobs({ 'linked-dir/target.txt': 'x', 'linked-file': 'y', 'ok.txt': 'ok' });

    const warnings = [];
    const result = await status({ dir, client, warn: (line) => warnings.push(line) });
    assert.deepEqual(result.upload, []);
    assert.deepEqual(keys(result.download), ['new ok.txt']);
    // push would not read the links, pull would not write through them.
    assert.deepEqual(warnings.sort(), [
      'skipping linked-dir/target.txt: linked-dir is a symbolic link',
      'skipping linked-dir: symbolic link',
      'skipping linked-file: symbolic link',
      'skipping linked-file: symbolic link',
    ]);
  });

  it('reports a blob pull could not write instead of failing', async () => {
    await putBlobs({ 'thing': 'file on the server', 'docs/sub/readme.txt': 'r', 'ok.txt': 'ok' });
    await writeTree(dir, { 'thing/inside.txt': 'local', 'docs/sub': 'a file' });

    const warnings = [];
    const result = await status({ dir, client, warn: (line) => warnings.push(line) });
    assert.deepEqual(keys(result.upload), ['new docs/sub', 'new thing/inside.txt']);
    assert.deepEqual(keys(result.download), ['new ok.txt']);
    assert.deepEqual(warnings, [
      'cannot write docs/sub/readme.txt: docs/sub is not a directory (pull would fail here)',
      'cannot write thing: a directory is in the way (pull would fail here)',
    ]);
  });

  it('fails when the directory does not exist, before contacting the server', async () => {
    await assert.rejects(status({ dir: path.join(dir, 'missing'), client }), { code: 'ENOENT' });
    assert.deepEqual(requests, []);
  });

  it('fails when the directory is a file', async () => {
    const file = path.join(dir, 'plain');
    await fs.writeFile(file, 'x');
    await assert.rejects(status({ dir: file, client }), { code: 'ENOTDIR' });
    assert.deepEqual(requests, []);
  });
});

describe('status against a server that misbehaves', () => {
  let tmp;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-status-err-'));
    await fs.writeFile(path.join(tmp, 'a.txt'), 'a');
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  it('fails promptly when nothing listens at the URL', async () => {
    const probe = net.createServer();
    const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
    await new Promise((resolve) => probe.close(resolve));

    const client = new SyncboxClient(new URL(`http://127.0.0.1:${port}`));
    await assert.rejects(status({ dir: tmp, client }), (err) => {
      assert.ok(err instanceof RequestError);
      assert.match(err.message, new RegExp(`^cannot reach server http://127\\.0\\.0\\.1:${port}/: .*ECONNREFUSED`));
      return true;
    });
  });

  it('fails when GET /blobs answers with an error status', async () => {
    const server = http.createServer((req, res) => {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end('{"error":"internal server error"}');
    });
    const client = new SyncboxClient(new URL(await listen(server)));
    try {
      await assert.rejects(status({ dir: tmp, client }), (err) => {
        assert.ok(err instanceof RequestError);
        assert.match(err.message, /^GET \/blobs: server answered 500/);
        return true;
      });
    } finally {
      await close(server);
    }
  });

  it('skips listed keys that are not relative paths, without requesting them', async () => {
    const requests = [];
    const listed = ['../escape.txt', '/abs.txt', 'a//b', 'nul\0.txt', 'fine.txt'].map((key) => ({
      key, sha256: sha256('x'), size: 1, modified_at: new Date().toISOString(),
    }));
    const server = http.createServer((req, res) => {
      requests.push(`${req.method} ${req.url}`);
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(listed));
    });
    const client = new SyncboxClient(new URL(await listen(server)));
    try {
      const warnings = [];
      const result = await status({ dir: tmp, client, warn: (line) => warnings.push(line) });
      assert.deepEqual(keys(result.download), ['new fine.txt']);
      assert.deepEqual(keys(result.upload), ['new a.txt']);
      assert.equal(warnings.length, 4);
      for (const line of warnings) {
        assert.match(line, /^skipping ".*": key is not a relative path inside the directory$/);
      }
      assert.deepEqual(requests, ['GET /blobs']);
    } finally {
      await close(server);
    }
  });
});

describe('formatStatus', () => {
  it('says so when there is nothing to do', () => {
    assert.deepEqual(formatStatus({ upload: [], download: [], upToDate: ['a', 'b'] }), [
      'Up to date: nothing to upload or download.',
      'status: 0 to upload, 0 to download, 2 up to date',
    ]);
  });

  it('lists uploads and downloads under separate headings', () => {
    assert.deepEqual(
      formatStatus({
        upload: [{ key: 'a/local.txt', reason: 'new' }, { key: 'changed.txt', reason: 'differs' }],
        download: [{ key: 'changed.txt', reason: 'differs' }, { key: 'remote.txt', reason: 'new' }],
        upToDate: ['same.txt'],
      }),
      [
        'Would upload to the server (push): 2 files',
        '  new      a/local.txt',
        '  differs  changed.txt',
        'Would download from the server (pull): 2 files',
        '  differs  changed.txt',
        '  new      remote.txt',
        "1 file differs on both sides: push would replace the server's copy, pull the local one.",
        'status: 2 to upload, 2 to download, 1 up to date',
      ],
    );
  });

  it('says "nothing" for a direction with nothing to transfer', () => {
    assert.deepEqual(formatStatus({ upload: [{ key: 'x', reason: 'new' }], download: [], upToDate: [] }), [
      'Would upload to the server (push): 1 file',
      '  new      x',
      'Would download from the server (pull): nothing',
      'status: 1 to upload, 0 to download, 0 up to date',
    ]);
  });

  it('quotes keys that would break the report', () => {
    const lines = formatStatus({ upload: [], download: [{ key: 'two\nlines', reason: 'new' }], upToDate: [] });
    assert.equal(lines[2], '  new      "two\\nlines"');
  });
});
