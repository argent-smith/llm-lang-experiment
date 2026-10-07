// pull() against a real Syncbox server running in-process on loopback, and
// against fake servers that misbehave in ways the real one does not.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';

import { RequestError, SyncboxClient } from '../src/client.js';
import { LocalConflictError, pull } from '../src/pull.js';
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

/** Every entry under `root` as "relative/path" -> contents (or "<dir>"/"<symlink>"). */
async function readTree(root) {
  const out = {};
  for (const entry of await fs.readdir(root, { recursive: true, withFileTypes: true })) {
    const full = path.join(entry.path, entry.name);
    const rel = path.relative(root, full).split(path.sep).join('/');
    if (entry.isSymbolicLink()) {
      out[rel] = '<symlink>';
    } else if (entry.isDirectory()) {
      out[rel] = '<dir>';
    } else {
      out[rel] = (await fs.readFile(full)).toString('latin1');
    }
  }
  return out;
}

describe('pull', () => {
  let tmp;
  let server;
  let baseUrl;
  let client;
  let dir;
  let requests;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-pull-'));
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

  const gets = () => requests.filter((r) => r.startsWith('GET /blobs/'));

  async function putBlobs(blobs) {
    for (const [key, content] of Object.entries(blobs)) {
      const url = `${baseUrl}/blobs/${key.split('/').map(encodeURIComponent).join('/')}`;
      const res = await fetch(url, { method: 'PUT', body: content });
      assert.equal(res.status, 201, key);
    }
    requests.length = 0;
  }

  it('downloads every blob into the directory, byte for byte, creating subdirectories', async () => {
    const blobs = {
      'readme.txt': 'hello\n',
      'docs/guide.md': '# Guide\n',
      'docs/deep/nested/data.bin': Buffer.from([0, 1, 2, 0xfe, 0xff, 0x0a, 0x0d]),
      'empty': '',
      '.hidden/.dotfile': 'dot',
      'with space/ünï ?#%&+;=.txt': 'odd name',
      'big.bin': Buffer.alloc(5 * 1024 * 1024 + 3, 0x5a),
    };
    await putBlobs(blobs);

    const log = [];
    const result = await pull({ dir, client, log: (line) => log.push(line) });

    const keys = Object.keys(blobs).sort();
    assert.deepEqual(result.downloaded, keys);
    assert.deepEqual(result.upToDate, []);
    assert.deepEqual(log, keys.map((k) => `downloaded ${k}`));
    for (const key of keys) {
      assert.deepEqual(await fs.readFile(path.join(dir, ...key.split('/'))), Buffer.from(blobs[key]), key);
    }
    // Nothing else: no temp files left over.
    const files = Object.entries(await readTree(dir)).filter(([, v]) => v !== '<dir>').map(([k]) => k);
    assert.deepEqual(files.sort(), keys);
  });

  it('does not download files that are already there with the same contents', async () => {
    await putBlobs({ 'a.txt': 'a', 'sub/b.txt': 'b', 'c.txt': 'c' });
    await pull({ dir, client });
    requests.length = 0;

    const result = await pull({ dir, client });
    assert.deepEqual(result.downloaded, []);
    assert.deepEqual(result.upToDate, ['a.txt', 'c.txt', 'sub/b.txt']);
    assert.deepEqual(requests, ['GET /blobs']);
  });

  it('downloads only the blobs that are missing or differ locally', async () => {
    await putBlobs({ 'same.txt': 'same', 'changed.txt': 'server version', 'sub/new.txt': 'brand new' });
    await writeTree(dir, { 'same.txt': 'same', 'changed.txt': 'local edit' });

    const result = await pull({ dir, client });
    assert.deepEqual(result.downloaded, ['changed.txt', 'sub/new.txt']);
    assert.deepEqual(result.upToDate, ['same.txt']);
    assert.deepEqual(gets(), ['GET /blobs/changed.txt', 'GET /blobs/sub/new.txt']);
    assert.equal(await fs.readFile(path.join(dir, 'changed.txt'), 'utf8'), 'server version');
    assert.equal(await fs.readFile(path.join(dir, 'sub/new.txt'), 'utf8'), 'brand new');
  });

  it('compares by SHA-256, not by size', async () => {
    await putBlobs({ 'f.txt': 'aaaa' });
    await writeTree(dir, { 'f.txt': 'bbbb' });
    const result = await pull({ dir, client });
    assert.deepEqual(result.downloaded, ['f.txt']);
    assert.equal(await fs.readFile(path.join(dir, 'f.txt'), 'utf8'), 'aaaa');
  });

  it('leaves files that exist only locally alone', async () => {
    await putBlobs({ 'server.txt': 'from server' });
    await writeTree(dir, { 'local.txt': 'keep me', 'sub/local.txt': 'me too' });

    await pull({ dir, client });
    assert.deepEqual(await readTree(dir), {
      'local.txt': 'keep me',
      'server.txt': 'from server',
      'sub': '<dir>',
      'sub/local.txt': 'me too',
    });
  });

  it('pushes nothing back: the server is left as it was', async () => {
    await putBlobs({ 'a.txt': 'a' });
    await writeTree(dir, { 'local.txt': 'local' });
    await pull({ dir, client });
    assert.ok(requests.every((r) => r.startsWith('GET ')), requests.join(', '));
  });

  it('percent-encodes each key segment', async () => {
    await putBlobs({ 'a b/%2F?#/ü.txt': 'x' });
    await pull({ dir, client });
    assert.deepEqual(gets(), ['GET /blobs/a%20b/%252F%3F%23/%C3%BC.txt']);
    assert.equal(await fs.readFile(path.join(dir, 'a b', '%2F?#', 'ü.txt'), 'utf8'), 'x');
  });

  it('creates the directory if it does not exist', async () => {
    await putBlobs({ 'a/b.txt': 'b' });
    const fresh = path.join(dir, 'not', 'yet');
    const result = await pull({ dir: fresh, client });
    assert.deepEqual(result.downloaded, ['a/b.txt']);
    assert.equal(await fs.readFile(path.join(fresh, 'a', 'b.txt'), 'utf8'), 'b');
  });

  it('fails when the directory is a file, before contacting the server', async () => {
    const file = path.join(dir, 'plain');
    await fs.writeFile(file, 'x');
    await assert.rejects(pull({ dir: file, client }), { code: 'ENOTDIR' });
    assert.deepEqual(requests, []);
  });

  it('keeps the permissions of a file it replaces', async () => {
    await putBlobs({ 'script.sh': '#!/bin/sh\necho new\n' });
    await writeTree(dir, { 'script.sh': '#!/bin/sh\necho old\n' });
    await fs.chmod(path.join(dir, 'script.sh'), 0o750);

    await pull({ dir, client });
    const stat = await fs.stat(path.join(dir, 'script.sh'));
    assert.equal(stat.mode & 0o777, 0o750);
    assert.equal(await fs.readFile(path.join(dir, 'script.sh'), 'utf8'), '#!/bin/sh\necho new\n');
  });

  it('does not write through symbolic links, reporting what it skips', async () => {
    const outside = path.join(dir, '..', 'outside');
    await writeTree(outside, { 'target.txt': 'outside file' });
    await fs.symlink(outside, path.join(dir, 'linked-dir'));
    await fs.symlink(path.join(outside, 'target.txt'), path.join(dir, 'linked-file'));
    await putBlobs({ 'linked-dir/target.txt': 'overwritten?', 'linked-dir/new.txt': 'planted?', 'linked-file': 'replaced?', 'ok.txt': 'ok' });

    const warnings = [];
    const result = await pull({ dir, client, warn: (line) => warnings.push(line) });
    assert.deepEqual(result.downloaded, ['ok.txt']);
    assert.deepEqual(warnings, [
      'skipping linked-dir/new.txt: linked-dir is a symbolic link',
      'skipping linked-dir/target.txt: linked-dir is a symbolic link',
      'skipping linked-file: symbolic link',
    ]);
    assert.deepEqual(await readTree(outside), { 'target.txt': 'outside file' });
    assert.equal(await fs.readlink(path.join(dir, 'linked-file')), path.join(outside, 'target.txt'));
  });

  it('fails when a directory is where a blob should go', async () => {
    await putBlobs({ 'a.txt': 'a', 'thing': 'file on the server', 'z.txt': 'z' });
    await writeTree(dir, { 'thing/inside.txt': 'local' });
    await assert.rejects(pull({ dir, client }), (err) => {
      assert.ok(err instanceof LocalConflictError);
      assert.equal(err.message, 'cannot write thing: a directory is in the way');
      return true;
    });
    assert.equal(await fs.readFile(path.join(dir, 'thing', 'inside.txt'), 'utf8'), 'local');
  });

  it('fails when a file is where a blob\'s directory should go', async () => {
    await putBlobs({ 'docs/sub/readme.txt': 'r' });
    await writeTree(dir, { 'docs/sub': 'a file' });
    await assert.rejects(pull({ dir, client }), (err) => {
      assert.ok(err instanceof LocalConflictError);
      assert.equal(err.message, 'cannot write docs/sub/readme.txt: docs/sub is not a directory');
      return true;
    });
    assert.equal(await fs.readFile(path.join(dir, 'docs', 'sub'), 'utf8'), 'a file');
  });

  it('accepts a server URL with a trailing slash', async () => {
    await putBlobs({ 'a.txt': 'a' });
    await pull({ dir, client: new SyncboxClient(new URL(`${baseUrl}/`)) });
    assert.deepEqual(gets(), ['GET /blobs/a.txt']);
  });
});

describe('pull from a server that misbehaves', () => {
  let tmp;
  let serial = 0;
  let dir;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-pull-err-'));
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  beforeEach(async () => {
    dir = path.join(tmp, `case-${++serial}`, 'local');
    await fs.mkdir(dir, { recursive: true });
  });

  /**
   * Starts a fake server: `list` is what GET /blobs answers, `handleBlob`
   * answers everything else. Returns a client for it and the requests seen.
   */
  async function fakeServer(list, handleBlob = (req, res) => res.writeHead(404).end()) {
    const requests = [];
    const server = http.createServer((req, res) => {
      requests.push(`${req.method} ${req.url}`);
      if (req.url === '/blobs') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(list));
      } else {
        handleBlob(req, res);
      }
    });
    const client = new SyncboxClient(new URL(await listen(server)));
    return { client, requests, close: () => close(server) };
  }

  const blob = (key, content) => ({ key, sha256: sha256(content), size: Buffer.byteLength(content), modified_at: new Date().toISOString() });

  it('fails promptly when nothing listens at the URL, writing nothing', async () => {
    const probe = net.createServer();
    const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
    await new Promise((resolve) => probe.close(resolve));

    const client = new SyncboxClient(new URL(`http://127.0.0.1:${port}`));
    const fresh = path.join(dir, 'fresh');
    await assert.rejects(pull({ dir: fresh, client }), (err) => {
      assert.ok(err instanceof RequestError);
      assert.match(err.message, new RegExp(`^cannot reach server http://127\\.0\\.0\\.1:${port}/: .*ECONNREFUSED`));
      return true;
    });
    await assert.rejects(fs.stat(fresh), { code: 'ENOENT' });
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
        await assert.rejects(pull({ dir, client }), (err) => {
          assert.ok(err instanceof RequestError);
          assert.match(err.message, /^GET \/blobs: /);
          return true;
        });
      } finally {
        await close(server);
      }
    });
  }

  it('never writes outside the directory, whatever keys the server lists', async () => {
    const evil = ['../escape.txt', 'a/../../escape.txt', '/tmp/absolute.txt', 'a//b.txt', './dot.txt', 'trailing/', '', 'nul\0.txt', 'lone-\ud800.txt'];
    const fake = await fakeServer([...evil.map((k) => blob(k, 'evil')), blob('fine.txt', 'fine')], (req, res) => res.end(req.url === '/blobs/fine.txt' ? 'fine' : 'evil'));
    try {
      const warnings = [];
      const result = await pull({ dir, client: fake.client, warn: (line) => warnings.push(line) });
      assert.deepEqual(result.downloaded, ['fine.txt']);
      assert.deepEqual(fake.requests, ['GET /blobs', 'GET /blobs/fine.txt']);
      assert.equal(warnings.length, evil.length);
      for (const line of warnings) {
        assert.match(line, /^skipping ".*": key is not a relative path inside the directory$/);
      }
      assert.deepEqual(await readTree(path.dirname(dir)), { 'local': '<dir>', 'local/fine.txt': 'fine' });
    } finally {
      await fake.close();
    }
  });

  it('fails with the server\'s reason when a listed blob cannot be fetched', async () => {
    const fake = await fakeServer([blob('gone.txt', 'x')], (req, res) => {
      res.writeHead(404, { 'Content-Type': 'application/json' }).end('{"error":"blob not found"}');
    });
    try {
      await assert.rejects(pull({ dir, client: fake.client }), (err) => {
        assert.ok(err instanceof RequestError);
        assert.equal(err.message, 'GET gone.txt: server answered 404 Not Found (blob not found)');
        return true;
      });
      assert.deepEqual(await readTree(dir), {});
    } finally {
      await fake.close();
    }
  });

  it('fails when the connection breaks off mid-download, leaving the local file as it was', async () => {
    const content = 'x'.repeat(1000);
    const fake = await fakeServer([blob('a.txt', content)], (req, res) => {
      res.writeHead(200, { 'Content-Length': String(content.length) });
      res.write(content.slice(0, 100), () => res.destroy());
    });
    await writeTree(dir, { 'a.txt': 'old local contents' });
    try {
      await assert.rejects(pull({ dir, client: fake.client }), (err) => {
        assert.ok(err instanceof RequestError);
        assert.match(err.message, /^GET a\.txt: download interrupted: /);
        return true;
      });
      assert.deepEqual(await readTree(dir), { 'a.txt': 'old local contents' });
    } finally {
      await fake.close();
    }
  });

  it('fails when the downloaded contents do not match the listed SHA-256', async () => {
    const fake = await fakeServer([blob('a.txt', 'listed')], (req, res) => res.end('served instead'));
    await writeTree(dir, { 'a.txt': 'old' });
    try {
      await assert.rejects(pull({ dir, client: fake.client }), (err) => {
        assert.ok(err instanceof RequestError);
        assert.match(err.message, /^GET a\.txt: the downloaded contents do not match the SHA-256 listed by the server/);
        return true;
      });
      assert.deepEqual(await readTree(dir), { 'a.txt': 'old' });
    } finally {
      await fake.close();
    }
  });

  it('stops when aborted mid-download, removing the partial file', async () => {
    const controller = new AbortController();
    const fake = await fakeServer([blob('done.txt', 'done'), blob('slow.txt', 'x'.repeat(1000))], (req, res) => {
      if (req.url === '/blobs/done.txt') {
        res.end('done');
        return;
      }
      // Half of the body, then nothing until the client gives up.
      res.writeHead(200, { 'Content-Length': '1000' });
      res.write('x'.repeat(500), () => setTimeout(() => controller.abort(), 50));
    });
    try {
      await assert.rejects(pull({ dir, client: fake.client, signal: controller.signal }), { name: 'AbortError' });
      assert.deepEqual(await readTree(dir), { 'done.txt': 'done' });
    } finally {
      await fake.close();
    }
  });
});
