// push() against a real Syncbox server running in-process on loopback.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';

import { RequestError, SyncboxClient, encodeKey } from '../src/client.js';
import { push } from '../src/push.js';
import { createServer } from '../src/server.js';

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

describe('push', () => {
  let tmp;
  let server;
  let baseUrl;
  let client;
  let dir;
  let requests;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-push-'));
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  let serial = 0;

  beforeEach(async () => {
    const name = `case-${++serial}`;
    dir = path.join(tmp, name, 'local');
    await fs.mkdir(dir, { recursive: true });
    server = createServer({ dataDir: path.join(tmp, name, 'data') });
    // Every request the server sees, as "METHOD path".
    requests = [];
    server.on('request', (req) => requests.push(`${req.method} ${req.url}`));
    baseUrl = await listen(server);
    client = new SyncboxClient(new URL(baseUrl));
  });

  afterEach(async () => {
    await close(server);
  });

  const puts = () => requests.filter((r) => r.startsWith('PUT '));

  async function serverBlobs() {
    const res = await fetch(`${baseUrl}/blobs`);
    return Object.fromEntries((await res.json()).map((b) => [b.key, b.sha256]));
  }

  async function serverContent(key) {
    const res = await fetch(`${baseUrl}/blobs/${encodeKey(key)}`);
    assert.equal(res.status, 200, key);
    return Buffer.from(await res.arrayBuffer());
  }

  it('uploads every file of a directory tree, byte for byte', async () => {
    const files = {
      'readme.txt': 'hello\n',
      'docs/guide.md': '# Guide\n',
      'docs/deep/nested/data.bin': Buffer.from([0, 1, 2, 0xfe, 0xff, 0x0a, 0x0d]),
      'empty': '',
      '.hidden/.dotfile': 'dot',
      'with space/ünï ?#%&+;=.txt': 'odd name',
      'big.bin': Buffer.alloc(5 * 1024 * 1024 + 3, 0x5a),
    };
    await writeTree(dir, files);

    const log = [];
    const result = await push({ dir, client, log: (line) => log.push(line) });

    const keys = Object.keys(files).sort();
    assert.deepEqual(result.uploaded, keys);
    assert.deepEqual(result.upToDate, []);
    assert.deepEqual(log, keys.map((k) => `uploaded ${k}`));
    assert.deepEqual(
      await serverBlobs(),
      Object.fromEntries(keys.map((k) => [k, sha256(Buffer.from(files[k]))])),
    );
    for (const key of keys) {
      assert.deepEqual(await serverContent(key), Buffer.from(files[key]), key);
    }
  });

  it('does not upload files that are already on the server with the same contents', async () => {
    await writeTree(dir, { 'a.txt': 'a', 'sub/b.txt': 'b', 'c.txt': 'c' });
    await push({ dir, client });
    requests.length = 0;

    const result = await push({ dir, client });
    assert.deepEqual(result.uploaded, []);
    assert.deepEqual(result.upToDate, ['a.txt', 'c.txt', 'sub/b.txt']);
    assert.deepEqual(requests, ['GET /blobs']);
  });

  it('uploads only the files that are new or changed', async () => {
    await writeTree(dir, { 'same.txt': 'same', 'changed.txt': 'old', 'sub/also-same.txt': 'x' });
    await push({ dir, client });
    requests.length = 0;

    await writeTree(dir, { 'changed.txt': 'new contents', 'sub/new.txt': 'brand new' });
    const result = await push({ dir, client });

    assert.deepEqual(result.uploaded, ['changed.txt', 'sub/new.txt']);
    assert.deepEqual(result.upToDate, ['same.txt', 'sub/also-same.txt']);
    assert.deepEqual(puts(), ['PUT /blobs/changed.txt', 'PUT /blobs/sub/new.txt']);
    assert.deepEqual(await serverContent('changed.txt'), Buffer.from('new contents'));
    assert.deepEqual(await serverContent('sub/new.txt'), Buffer.from('brand new'));
  });

  it('compares by SHA-256, not by size', async () => {
    // Same key and size on both sides, different bytes.
    await fetch(`${baseUrl}/blobs/f.txt`, { method: 'PUT', body: 'aaaa' });
    await writeTree(dir, { 'f.txt': 'bbbb' });
    requests.length = 0;

    const result = await push({ dir, client });
    assert.deepEqual(result.uploaded, ['f.txt']);
    assert.deepEqual(puts(), ['PUT /blobs/f.txt']);
    assert.deepEqual(await serverContent('f.txt'), Buffer.from('bbbb'));
  });

  it('leaves blobs that exist only on the server alone', async () => {
    await fetch(`${baseUrl}/blobs/server-only.txt`, { method: 'PUT', body: 'keep me' });
    await writeTree(dir, { 'local.txt': 'local' });

    await push({ dir, client });
    assert.deepEqual(Object.keys(await serverBlobs()), ['local.txt', 'server-only.txt']);
    assert.deepEqual(await serverContent('server-only.txt'), Buffer.from('keep me'));
  });

  it('percent-encodes each key segment', async () => {
    await writeTree(dir, { 'a b/%2F?#/ü.txt': 'x' });
    await push({ dir, client });
    assert.deepEqual(puts(), [`PUT /blobs/a%20b/%252F%3F%23/%C3%BC.txt`]);
    assert.deepEqual(Object.keys(await serverBlobs()), ['a b/%2F?#/ü.txt']);
  });

  it('skips symbolic links, reporting them', async () => {
    await writeTree(dir, { 'real.txt': 'r' });
    await fs.symlink('real.txt', path.join(dir, 'link.txt'));
    const warnings = [];
    const result = await push({ dir, client, warn: (line) => warnings.push(line) });
    assert.deepEqual(result.uploaded, ['real.txt']);
    assert.deepEqual(warnings, ['skipping link.txt: symbolic link']);
  });

  it('accepts a server URL with a trailing slash', async () => {
    await writeTree(dir, { 'a.txt': 'a' });
    await push({ dir, client: new SyncboxClient(new URL(`${baseUrl}/`)) });
    assert.deepEqual(puts(), ['PUT /blobs/a.txt']);
  });

  it('fails when the directory does not exist, before contacting the server', async () => {
    await assert.rejects(push({ dir: path.join(dir, 'missing'), client }), { code: 'ENOENT' });
    assert.deepEqual(requests, []);
  });

  it('fails with the server\'s reason when an upload is rejected', async () => {
    // "clash" is a blob on the server, so "clash/inner.txt" cannot be stored.
    await fetch(`${baseUrl}/blobs/clash`, { method: 'PUT', body: 'file' });
    await writeTree(dir, { 'clash/inner.txt': 'x' });
    await assert.rejects(push({ dir, client }), (err) => {
      assert.ok(err instanceof RequestError);
      assert.match(err.message, /^PUT clash\/inner\.txt: server answered 400 Bad Request \(invalid key: .+\)$/);
      return true;
    });
  });
});

describe('push to a server that misbehaves', () => {
  let tmp;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-push-err-'));
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
    await assert.rejects(push({ dir: tmp, client }), (err) => {
      assert.ok(err instanceof RequestError);
      assert.match(err.message, new RegExp(`^cannot reach server http://127\\.0\\.0\\.1:${port}/: .*ECONNREFUSED`));
      return true;
    });
  });

  for (const [what, status, body] of [
    ['an error status', 500, '{"error":"internal server error"}'],
    ['something other than JSON', 200, '<html>proxy page</html>'],
    ['JSON that is not a list of blobs', 200, '{"key":"a.txt"}'],
  ]) {
    it(`fails when GET /blobs answers with ${what}`, async () => {
      const server = http.createServer((req, res) => {
        res.writeHead(status, { 'Content-Type': 'application/json' });
        res.end(body);
      });
      const client = new SyncboxClient(new URL(await listen(server)));
      try {
        await assert.rejects(push({ dir: tmp, client }), (err) => {
          assert.ok(err instanceof RequestError);
          assert.match(err.message, /^GET \/blobs: /);
          return true;
        });
      } finally {
        await close(server);
      }
    });
  }
});
