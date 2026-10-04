// Network errors and partial failures: timeouts and unreachable servers in
// SyncboxClient, and push/pull/sync/status going on past files that fail.
// The faults are injected by a wrapper around a real server running
// in-process on loopback.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Writable } from 'node:stream';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';

import { RequestError, SyncboxClient, UnreachableError, encodeKey } from '../src/client.js';
import { Failures, LocalConflictError, failureCounts, formatFailures } from '../src/failures.js';
import { pull } from '../src/pull.js';
import { push } from '../src/push.js';
import { createServer } from '../src/server.js';
import { status } from '../src/status.js';
import { loadState, stateFile } from '../src/sync-state.js';
import { sync } from '../src/sync.js';

const sha256 = (data) => createHash('sha256').update(data).digest('hex');

// Short, so that the tests do not wait long for the client to give up.
const TIMEOUTS = { connectTimeout: 500, responseTimeout: 300 };

// Root can read files whatever their permissions.
const asRoot = process.getuid?.() === 0 && 'root ignores permissions';

async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}

/** A port on loopback that nothing listens on. */
async function closedPort() {
  const probe = net.createServer();
  const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

async function writeTree(root, files) {
  for (const [rel, content] of Object.entries(files)) {
    await fs.mkdir(path.dirname(path.join(root, rel)), { recursive: true });
    await fs.writeFile(path.join(root, rel), content);
  }
}

/** Every file under `root` as "relative/path" -> contents. */
async function readFiles(root) {
  const out = {};
  for (const entry of await fs.readdir(root, { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) {
      const full = path.join(entry.path, entry.name);
      out[path.relative(root, full).split(path.sep).join('/')] = await fs.readFile(full, 'utf8');
    }
  }
  return out;
}

/** Measures how long `promise` takes to settle. */
async function timed(promise) {
  const start = performance.now();
  try {
    return { value: await promise, ms: performance.now() - start };
  } catch (error) {
    return { error, ms: performance.now() - start };
  }
}

const brokenBy = (result) => result.failed.map(({ key, reason }) => [key, reason]);

const discard = () => new Writable({ write: (chunk, encoding, done) => done() });

describe('SyncboxClient when the server cannot be reached', () => {
  it('fails promptly with UnreachableError when the connection is refused', async () => {
    const port = await closedPort();
    const client = new SyncboxClient(new URL(`http://127.0.0.1:${port}`), TIMEOUTS);
    const { error, ms } = await timed(client.list());
    assert.ok(error instanceof UnreachableError, error);
    assert.match(error.message, new RegExp(`^cannot reach server http://127\\.0\\.0\\.1:${port}/: connection refused \\(.*ECONNREFUSED`));
    assert.ok(ms < TIMEOUTS.connectTimeout, `took ${ms} ms`);
  });

  it('fails with UnreachableError when the host name does not resolve', async () => {
    // .invalid never resolves (RFC 2606). Without a network to ask, the
    // lookup fails differently, or times out: unreachable either way.
    const client = new SyncboxClient(new URL('http://syncbox-test.invalid:8080'), TIMEOUTS);
    const { error, ms } = await timed(client.list());
    assert.ok(error instanceof UnreachableError, error);
    assert.match(error.message, /^cannot reach server http:\/\/syncbox-test\.invalid:8080\/: /);
    assert.ok(ms < 5000, `took ${ms} ms`);
  });

  it('gives up connecting after connectTimeout', async () => {
    // TEST-NET-1 (RFC 5737) is never routed: the connection attempt either
    // goes unanswered until the timeout or fails at once for want of a route.
    const client = new SyncboxClient(new URL('http://192.0.2.1:8080'), TIMEOUTS);
    const { error, ms } = await timed(client.list());
    assert.ok(error instanceof UnreachableError, error);
    assert.match(error.message, /^cannot reach server http:\/\/192\.0\.2\.1:8080\/: (no connection within 500 ms \(timed out\)|.*unreachable)/);
    assert.ok(ms < TIMEOUTS.connectTimeout + 1000, `took ${ms} ms`);
  });

  it('has default timeouts, so that no request waits forever', () => {
    const client = new SyncboxClient(new URL('http://127.0.0.1:8080'));
    assert.ok(client.connectTimeout > 0 && Number.isFinite(client.connectTimeout));
    assert.ok(client.responseTimeout > 0 && Number.isFinite(client.responseTimeout));
  });
});

describe('SyncboxClient when the server stops answering', () => {
  let tmp;
  let server;
  let client;
  let handle;
  let held;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-timeout-'));
    await fs.writeFile(path.join(tmp, 'upload.txt'), 'x'.repeat(1000));
    held = [];
    server = http.createServer((req, res) => {
      held.push(res);
      handle(req, res);
    });
    client = new SyncboxClient(new URL(await listen(server)), TIMEOUTS);
  });

  after(async () => {
    await close(server);
    await fs.rm(tmp, { recursive: true, force: true });
  });

  afterEach(() => {
    for (const res of held.splice(0)) {
      res.destroy();
    }
  });

  it('times out when a connection is accepted but no response comes', async () => {
    handle = () => {};
    const { error, ms } = await timed(client.list());
    assert.ok(error instanceof RequestError, error);
    assert.ok(!(error instanceof UnreachableError));
    assert.equal(error.message, 'GET /blobs: timed out: no response from the server within 300 ms');
    assert.ok(ms >= TIMEOUTS.responseTimeout - 50 && ms < TIMEOUTS.responseTimeout + 1000, `took ${ms} ms`);
  });

  it('times out when the response stops halfway', async () => {
    handle = (req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.write('[{"key":');
    };
    const { error } = await timed(client.list());
    assert.ok(error instanceof RequestError, error);
    assert.equal(error.message, 'GET /blobs: timed out: the server sent nothing for 300 ms');
  });

  it('times out an upload the server never answers', async () => {
    handle = (req) => req.resume();
    const { error } = await timed(client.put('upload.txt', path.join(tmp, 'upload.txt')));
    assert.ok(error instanceof RequestError, error);
    assert.equal(error.message, 'PUT upload.txt: timed out: no response from the server within 300 ms');
    assert.equal(error.reason, 'timed out: no response from the server within 300 ms');
  });

  it('times out a download that stalls', async () => {
    handle = (req, res) => {
      res.writeHead(200, { 'Content-Length': '1000' });
      res.write('x'.repeat(500));
    };
    const { error } = await timed(client.download('stalled.bin', discard()));
    assert.ok(error instanceof RequestError, error);
    assert.equal(error.message, 'GET stalled.bin: timed out: the server sent nothing for 300 ms');
  });

  it('times out on a connection kept alive from an earlier request as well', async () => {
    let connections = 0;
    const count = () => connections++;
    server.on('connection', count);
    let answered = false;
    handle = (req, res) => {
      if (!answered) {
        answered = true;
        res.writeHead(200, { 'Content-Type': 'application/json' }).end('[]');
      }
    };
    try {
      assert.deepEqual(await client.list(), []);
      const { error } = await timed(client.list());
      assert.ok(error instanceof RequestError, error);
      assert.equal(error.message, 'GET /blobs: timed out: no response from the server within 300 ms');
      assert.equal(connections, 1);
    } finally {
      server.off('connection', count);
    }
  });

  it('does not time out a response that keeps coming, however long it takes in all', async () => {
    const body = 'y'.repeat(10);
    handle = (req, res) => {
      res.writeHead(200, { 'Content-Length': String(body.length) });
      // 10 bytes over about 1 s: longer than the timeout, but never idle for that long.
      let sent = 0;
      const timer = setInterval(() => {
        res.write(body[sent++]);
        if (sent === body.length) {
          clearInterval(timer);
          res.end();
        }
      }, 100);
    };
    const received = await client.download('slow.bin', discard());
    assert.equal(received.sha256, sha256(body));
  });
});

/**
 * A real server behind a wrapper that lets `fault` answer a request instead:
 * if `fault(req, res)` returns true, the request is left to it.
 */
async function faultyServer(dataDir, fault) {
  const real = createServer({ dataDir });
  const handle = real.listeners('request')[0];
  const requests = [];
  const server = http.createServer((req, res) => {
    requests.push(`${req.method} ${req.url}`);
    if (!fault(req, res)) {
      handle(req, res);
    }
  });
  const url = await listen(server);
  return { url, requests, server, close: () => close(server) };
}

// Fault injections.
const fail500 = (res) => res.writeHead(500, { 'Content-Type': 'application/json' }).end('{"error":"boom"}');
const resetConnection = (req) => req.socket.destroy();
const neverAnswer = () => {};

describe('partial failures', () => {
  let tmp;
  let serial = 0;
  let dir;
  let dataDir;
  let stateDir;
  let fake;
  let client;
  // Set by a test: answers a request instead of the real server.
  let fault;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-partial-'));
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  beforeEach(async () => {
    const name = `case-${++serial}`;
    dir = path.join(tmp, name, 'local');
    dataDir = path.join(tmp, name, 'data');
    stateDir = path.join(tmp, name, 'state');
    await fs.mkdir(dir, { recursive: true });
    fault = () => false;
    fake = await faultyServer(dataDir, (req, res) => fault(req, res));
    client = new SyncboxClient(new URL(fake.url), TIMEOUTS);
  });

  afterEach(async () => {
    await fake.close();
  });

  /** Makes `METHOD /blobs/<key>` fail with `inject`. */
  const breakRequest = (method, key, inject) => {
    fault = (req, res) => {
      if (req.method === method && req.url === `/blobs/${encodeKey(key)}`) {
        inject(res, req);
        return true;
      }
      return false;
    };
  };

  async function putBlobs(blobs) {
    for (const [key, content] of Object.entries(blobs)) {
      const res = await fetch(`${fake.url}/blobs/${encodeKey(key)}`, { method: 'PUT', body: content });
      assert.equal(res.status, 201, key);
    }
  }

  async function serverFiles() {
    const out = {};
    for (const { key } of await (await fetch(`${fake.url}/blobs`)).json()) {
      out[key] = await (await fetch(`${fake.url}/blobs/${encodeKey(key)}`)).text();
    }
    return out;
  }

  describe('push', () => {
    const files = { 'a.txt': 'a', 'bad.txt': 'bad', 'sub/c.txt': 'c' };

    it('uploads the other files when the server answers 5xx for one', async () => {
      await writeTree(dir, files);
      breakRequest('PUT', 'bad.txt', fail500);
      const result = await push({ dir, client });
      assert.deepEqual(result.uploaded, ['a.txt', 'sub/c.txt']);
      assert.deepEqual(brokenBy(result), [['bad.txt', 'upload failed: server answered 500 Internal Server Error (boom)']]);
      assert.equal(result.stopped, undefined);
      assert.deepEqual(await serverFiles(), { 'a.txt': 'a', 'sub/c.txt': 'c' });
    });

    it('uploads the other files when the connection breaks for one', async () => {
      await writeTree(dir, files);
      breakRequest('PUT', 'bad.txt', (res, req) => resetConnection(req));
      const result = await push({ dir, client });
      assert.deepEqual(result.uploaded, ['a.txt', 'sub/c.txt']);
      assert.deepEqual(result.failed.map((f) => f.key), ['bad.txt']);
      assert.match(result.failed[0].reason, /^upload failed: request failed: /);
    });

    it('uploads the other files when one upload times out', async () => {
      await writeTree(dir, files);
      breakRequest('PUT', 'bad.txt', neverAnswer);
      const result = await push({ dir, client });
      assert.deepEqual(result.uploaded, ['a.txt', 'sub/c.txt']);
      assert.deepEqual(brokenBy(result), [['bad.txt', 'upload failed: timed out: no response from the server within 300 ms']]);
    });

    it('uploads the other files when one cannot be read', { skip: asRoot }, async () => {
      await writeTree(dir, files);
      await fs.chmod(path.join(dir, 'bad.txt'), 0o000);
      const result = await push({ dir, client });
      assert.deepEqual(result.uploaded, ['a.txt', 'sub/c.txt']);
      assert.deepEqual(result.failed.map((f) => f.key), ['bad.txt']);
      assert.match(result.failed[0].reason, /^EACCES: permission denied, open '.*bad\.txt'$/);
    });

    it('uploads the other files when a subdirectory cannot be read', { skip: asRoot }, async () => {
      await writeTree(dir, { ...files, 'locked/x.txt': 'x' });
      await fs.chmod(path.join(dir, 'locked'), 0o000);
      try {
        const result = await push({ dir, client });
        assert.deepEqual(result.uploaded, ['a.txt', 'bad.txt', 'sub/c.txt']);
        assert.deepEqual(result.failed.map((f) => f.key), ['locked/']);
        assert.match(result.failed[0].reason, /^EACCES: permission denied, scandir '.*locked'$/);
      } finally {
        await fs.chmod(path.join(dir, 'locked'), 0o755);
      }
    });

    it('stops when the server goes away midway, counting what was left undone', async () => {
      await writeTree(dir, { 'a.txt': 'a', 'b.txt': 'b', 'c.txt': 'c', 'd.txt': 'd' });
      // The server dies while receiving b.txt: that request breaks off, and
      // the next cannot connect at all.
      breakRequest('PUT', 'b.txt', (res, req) => {
        fake.server.close();
        fake.server.closeAllConnections();
        resetConnection(req);
      });
      const result = await push({ dir, client });
      assert.deepEqual(result.uploaded, ['a.txt']);
      assert.deepEqual(result.failed.map((f) => f.key), ['b.txt']);
      assert.ok(result.stopped.error instanceof UnreachableError);
      assert.match(result.stopped.error.message, /^cannot reach server .*: connection refused/);
      assert.equal(result.stopped.remaining, 2);
      assert.deepEqual(fake.requests, ['GET /blobs', 'PUT /blobs/a.txt', 'PUT /blobs/b.txt']);
    });

    it('fails outright when the server cannot be reached to begin with', async () => {
      await writeTree(dir, files);
      const unreachable = new SyncboxClient(new URL(`http://127.0.0.1:${await closedPort()}`), TIMEOUTS);
      await assert.rejects(push({ dir, client: unreachable }), UnreachableError);
    });

    it('fails outright when GET /blobs times out', async () => {
      await writeTree(dir, files);
      fault = (req) => req.url === '/blobs';
      await assert.rejects(push({ dir, client }), {
        name: 'RequestError',
        message: 'GET /blobs: timed out: no response from the server within 300 ms',
      });
    });
  });

  describe('pull', () => {
    const blobs = { 'a.txt': 'a', 'bad.txt': 'bad', 'sub/c.txt': 'c' };

    it('downloads the other blobs when the server answers 5xx for one', async () => {
      await putBlobs(blobs);
      breakRequest('GET', 'bad.txt', fail500);
      const result = await pull({ dir, client });
      assert.deepEqual(result.downloaded, ['a.txt', 'sub/c.txt']);
      assert.deepEqual(brokenBy(result), [['bad.txt', 'download failed: server answered 500 Internal Server Error (boom)']]);
      // No partial file left behind for the one that failed.
      assert.deepEqual(await readFiles(dir), { 'a.txt': 'a', 'sub/c.txt': 'c' });
      assert.deepEqual(await fs.readdir(dir), ['a.txt', 'sub']);
    });

    it('downloads the other blobs when one download breaks off midway', async () => {
      await putBlobs(blobs);
      breakRequest('GET', 'bad.txt', (res) => {
        res.writeHead(200, { 'Content-Length': '1000' });
        res.write('x'.repeat(10), () => res.destroy());
      });
      await writeTree(dir, { 'bad.txt': 'old local copy' });
      const result = await pull({ dir, client });
      assert.deepEqual(result.downloaded, ['a.txt', 'sub/c.txt']);
      assert.deepEqual(result.failed.map((f) => f.key), ['bad.txt']);
      assert.match(result.failed[0].reason, /^download failed: download interrupted: /);
      assert.deepEqual(await readFiles(dir), { 'a.txt': 'a', 'bad.txt': 'old local copy', 'sub/c.txt': 'c' });
    });

    it('downloads the other blobs when one download stalls', async () => {
      await putBlobs(blobs);
      breakRequest('GET', 'bad.txt', (res) => {
        res.writeHead(200, { 'Content-Length': '1000' });
        res.write('x'.repeat(10));
      });
      const result = await pull({ dir, client });
      assert.deepEqual(result.downloaded, ['a.txt', 'sub/c.txt']);
      assert.deepEqual(brokenBy(result), [['bad.txt', 'download failed: timed out: the server sent nothing for 300 ms']]);
      assert.deepEqual(await fs.readdir(dir), ['a.txt', 'sub']);
    });

    it('downloads the other blobs when one cannot be written', { skip: asRoot }, async () => {
      await putBlobs(blobs);
      await fs.mkdir(path.join(dir, 'sub'));
      await fs.chmod(path.join(dir, 'sub'), 0o555);
      try {
        const result = await pull({ dir, client });
        assert.deepEqual(result.downloaded, ['a.txt', 'bad.txt']);
        assert.deepEqual(result.failed.map((f) => f.key), ['sub/c.txt']);
        assert.match(result.failed[0].reason, /^EACCES: permission denied/);
      } finally {
        await fs.chmod(path.join(dir, 'sub'), 0o755);
      }
    });

    it('stops when the server goes away midway', async () => {
      await putBlobs({ 'a.txt': 'a', 'b.txt': 'b', 'c.txt': 'c' });
      breakRequest('GET', 'a.txt', (res, req) => {
        fake.server.close();
        fake.server.closeAllConnections();
        resetConnection(req);
      });
      const result = await pull({ dir, client });
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.failed.map((f) => f.key), ['a.txt']);
      assert.ok(result.stopped.error instanceof UnreachableError);
      assert.equal(result.stopped.remaining, 2);
      assert.deepEqual(await fs.readdir(dir), []);
    });
  });

  describe('sync', () => {
    it('transfers the rest when one upload and one download fail, and catches up next time', async () => {
      await writeTree(dir, { 'up-ok.txt': 'u', 'up-bad.txt': 'U' });
      await putBlobs({ 'down-ok.txt': 'd', 'down-bad.txt': 'D' });
      fault = (req, res) => {
        if (req.url === '/blobs/up-bad.txt' || req.url === '/blobs/down-bad.txt') {
          fail500(res);
          return true;
        }
        return false;
      };

      const result = await sync({ dir, client, stateDir });
      assert.deepEqual(result.uploaded, ['up-ok.txt']);
      assert.deepEqual(result.downloaded, ['down-ok.txt']);
      assert.deepEqual(brokenBy(result), [
        ['down-bad.txt', 'download failed: server answered 500 Internal Server Error (boom)'],
        ['up-bad.txt', 'upload failed: server answered 500 Internal Server Error (boom)'],
      ]);
      // Only what was synced is remembered as in common.
      const file = await stateFile(stateDir, client.base, dir);
      assert.deepEqual(await loadState(file), new Map([['down-ok.txt', sha256('d')], ['up-ok.txt', sha256('u')]]));

      fault = () => false;
      const again = await sync({ dir, client, stateDir });
      assert.deepEqual(again.uploaded, ['up-bad.txt']);
      assert.deepEqual(again.downloaded, ['down-bad.txt']);
      assert.deepEqual(again.failed, []);
      const all = { 'down-bad.txt': 'D', 'down-ok.txt': 'd', 'up-bad.txt': 'U', 'up-ok.txt': 'u' };
      assert.deepEqual(await readFiles(dir), all);
      assert.deepEqual(await serverFiles(), all);
    });

    it('leaves a file it cannot read alone, rather than overwrite it with the server copy', { skip: asRoot }, async () => {
      await writeTree(dir, { 'secret.txt': 'local edit', 'ok.txt': 'ok' });
      await putBlobs({ 'secret.txt': 'server version' });
      await fs.chmod(path.join(dir, 'secret.txt'), 0o000);
      try {
        const result = await sync({ dir, client, stateDir });
        assert.deepEqual(result.uploaded, ['ok.txt']);
        assert.deepEqual(result.downloaded, []);
        assert.deepEqual(result.failed.map((f) => f.key), ['secret.txt']);
        assert.match(result.failed[0].reason, /^EACCES: /);
      } finally {
        await fs.chmod(path.join(dir, 'secret.txt'), 0o644);
      }
      assert.equal(await fs.readFile(path.join(dir, 'secret.txt'), 'utf8'), 'local edit');
      assert.equal((await serverFiles())['secret.txt'], 'server version');
    });

    it('leaves the blobs under a directory it cannot read alone', { skip: asRoot }, async () => {
      await writeTree(dir, { 'locked/mine.txt': 'local edit', 'ok.txt': 'ok' });
      await putBlobs({ 'locked/mine.txt': 'server version', 'locked/new.txt': 'new' });
      await fs.chmod(path.join(dir, 'locked'), 0o333);
      try {
        const result = await sync({ dir, client, stateDir });
        assert.deepEqual(result.uploaded, ['ok.txt']);
        assert.deepEqual(result.downloaded, []);
        assert.deepEqual(result.failed.map((f) => f.key), ['locked/']);
      } finally {
        await fs.chmod(path.join(dir, 'locked'), 0o755);
      }
      assert.deepEqual(await readFiles(dir), { 'locked/mine.txt': 'local edit', 'ok.txt': 'ok' });
    });

    it('stops when the server goes away midway, saving what got done', async () => {
      await writeTree(dir, { 'a.txt': 'a', 'b.txt': 'b', 'c.txt': 'c' });
      breakRequest('PUT', 'b.txt', (res, req) => {
        fake.server.close();
        fake.server.closeAllConnections();
        resetConnection(req);
      });
      const result = await sync({ dir, client, stateDir });
      assert.deepEqual(result.uploaded, ['a.txt']);
      assert.deepEqual(result.failed.map((f) => f.key), ['b.txt']);
      assert.equal(result.stopped.remaining, 1);
      const file = await stateFile(stateDir, client.base, dir);
      assert.deepEqual(await loadState(file), new Map([['a.txt', sha256('a')]]));
    });
  });

  describe('status', () => {
    it('reports the other files when one cannot be read', { skip: asRoot }, async () => {
      await writeTree(dir, { 'a.txt': 'a', 'bad.txt': 'local', 'same.txt': 's' });
      await putBlobs({ 'bad.txt': 'server', 'same.txt': 's', 'remote.txt': 'r' });
      await fs.chmod(path.join(dir, 'bad.txt'), 0o000);
      try {
        const result = await status({ dir, client });
        assert.deepEqual(result.upload, [{ key: 'a.txt', reason: 'new' }]);
        assert.deepEqual(result.download, [{ key: 'remote.txt', reason: 'new' }]);
        assert.deepEqual(result.upToDate, ['same.txt']);
        assert.deepEqual(result.failed.map((f) => f.key), ['bad.txt']);
        assert.match(result.failed[0].reason, /^EACCES: /);
      } finally {
        await fs.chmod(path.join(dir, 'bad.txt'), 0o644);
      }
    });

    it('fails outright when GET /blobs times out', async () => {
      fault = (req) => req.url === '/blobs';
      await assert.rejects(status({ dir, client }), { message: 'GET /blobs: timed out: no response from the server within 300 ms' });
    });
  });
});

describe('Failures', () => {
  it('records expected failures and goes on', async () => {
    const failures = new Failures();
    const done = [];
    await failures.each([{ key: 'a' }, { key: 'b' }, { key: 'c' }, { key: 'd' }], 'upload', async ({ key }) => {
      if (key === 'b') {
        throw new RequestError('PUT b: server answered 500', { reason: 'server answered 500' });
      }
      if (key === 'c') {
        throw new LocalConflictError('c', 'a directory is in the way');
      }
      done.push(key);
    });
    assert.deepEqual(done, ['a', 'd']);
    assert.deepEqual(brokenBy(failures.result()), [['b', 'upload failed: server answered 500'], ['c', 'a directory is in the way']]);
  });

  it('stops at an UnreachableError', async () => {
    const failures = new Failures();
    const done = [];
    await failures.each([{ key: 'a' }, { key: 'b' }, { key: 'c' }], 'upload', async ({ key }) => {
      if (key === 'b') {
        throw new UnreachableError('cannot reach server http://x/: connection refused');
      }
      done.push(key);
    });
    assert.deepEqual(done, ['a']);
    assert.deepEqual(failures.files, []);
    assert.equal(failures.stopped.remaining, 2);
    assert.deepEqual(Object.keys(failures.result()), ['failed', 'stopped']);
  });

  it('lets interruptions and bugs through', async () => {
    const failures = new Failures();
    const abort = new DOMException('stop', 'AbortError');
    await assert.rejects(failures.each([{ key: 'a' }], 'upload', async () => { throw abort; }), (err) => err === abort);
    await assert.rejects(failures.each([{ key: 'a' }], 'upload', async () => { throw new TypeError('oops'); }), TypeError);
    assert.deepEqual(failures.files, []);
    assert.deepEqual(failures.result(), { failed: [] });
  });

  it('formats the report and the counts', () => {
    const result = {
      failed: [
        { key: 'a.txt', reason: 'upload failed: server answered 500 Internal Server Error (boom)' },
        { key: 'two\nlines', reason: 'EACCES: permission denied' },
      ],
      stopped: { error: new UnreachableError('cannot reach server http://x/: connection refused'), remaining: 3 },
    };
    assert.deepEqual(formatFailures('push', result), [
      'push: 2 failed:',
      '  a.txt: upload failed: server answered 500 Internal Server Error (boom)',
      '  "two\\nlines": EACCES: permission denied',
      'push stopped, 3 not attempted: cannot reach server http://x/: connection refused',
    ]);
    assert.equal(failureCounts(result), ', 2 failed, 3 not attempted');
    assert.deepEqual(formatFailures('push', { failed: [] }), []);
    assert.equal(failureCounts({ failed: [] }), '');
  });
});
