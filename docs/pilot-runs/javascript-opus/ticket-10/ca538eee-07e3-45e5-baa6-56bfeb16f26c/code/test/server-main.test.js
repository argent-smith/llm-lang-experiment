// End-to-end tests of the server entry point: spawns `node src/server-main.js`
// as a real process and talks to it over HTTP.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const MAIN = fileURLToPath(new URL('../src/server-main.js', import.meta.url));

// Environment without any SYNCBOX_* variables inherited from the test runner.
const CLEAN_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('SYNCBOX_')));

function startServer(args, env = {}) {
  const child = spawn(process.execPath, [MAIN, ...args], {
    env: { ...CLEAN_ENV, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => (stdout += d));
  child.stderr.on('data', (d) => (stderr += d));
  const exited = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal })));
  return { child, exited, output: () => ({ stdout, stderr }) };
}

async function freePort() {
  const srv = net.createServer();
  await new Promise((resolve) => srv.listen(0, '127.0.0.1', resolve));
  const { port } = srv.address();
  await new Promise((resolve) => srv.close(resolve));
  return port;
}

async function waitForHealthy(port, proc, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    if (proc.child.exitCode !== null) {
      throw new Error(`server exited early: ${JSON.stringify(proc.output())}`);
    }
    try {
      const res = await fetch(`http://127.0.0.1:${port}/healthz`);
      await res.body?.cancel();
      if (res.status === 200) return;
    } catch (err) {
      lastError = err;
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server did not become healthy on port ${port}: ${lastError}`);
}

async function stop(proc) {
  if (proc.child.exitCode === null && proc.child.signalCode === null) {
    proc.child.kill('SIGTERM');
  }
  return proc.exited;
}

describe('server-main', () => {
  let tmp;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-test-'));
  });

  after(async () => {
    await fs.rm(tmp, { recursive: true, force: true });
  });

  it('serves /healthz on the port given by --port', async () => {
    const port = await freePort();
    const proc = startServer(['--data-dir', path.join(tmp, 'flags'), '--port', String(port)]);
    try {
      await waitForHealthy(port, proc);
    } finally {
      await stop(proc);
    }
  });

  it('is configurable through SYNCBOX_DATA_DIR and SYNCBOX_PORT', async () => {
    const port = await freePort();
    const proc = startServer([], { SYNCBOX_DATA_DIR: path.join(tmp, 'env'), SYNCBOX_PORT: String(port) });
    try {
      await waitForHealthy(port, proc);
    } finally {
      await stop(proc);
    }
  });

  it('creates a missing data directory', async () => {
    const dataDir = path.join(tmp, 'nested', 'does', 'not', 'exist');
    const port = await freePort();
    const proc = startServer(['--data-dir', dataDir, '--port', String(port)]);
    try {
      await waitForHealthy(port, proc);
      assert.ok((await fs.stat(dataDir)).isDirectory());
    } finally {
      await stop(proc);
    }
  });

  it('stores a blob under the data directory and serves it back', async () => {
    const dataDir = path.join(tmp, 'blobs-e2e');
    const port = await freePort();
    const proc = startServer(['--data-dir', dataDir, '--port', String(port)]);
    try {
      await waitForHealthy(port, proc);
      const body = Buffer.from([0, 1, 2, 0xfe, 0xff, 0x0a]);
      const putRes = await fetch(`http://127.0.0.1:${port}/blobs/docs/readme.txt`, { method: 'PUT', body });
      assert.equal(putRes.status, 201);
      assert.equal((await putRes.json()).size, body.length);

      const getRes = await fetch(`http://127.0.0.1:${port}/blobs/docs/readme.txt`);
      assert.equal(getRes.status, 200);
      assert.deepEqual(Buffer.from(await getRes.arrayBuffer()), body);
      assert.deepEqual(await fs.readFile(path.join(dataDir, 'blobs', 'docs', 'readme.txt')), body);

      const listRes = await fetch(`http://127.0.0.1:${port}/blobs`);
      assert.equal(listRes.status, 200);
      const [entry, ...rest] = await listRes.json();
      assert.deepEqual(rest, []);
      assert.equal(entry.key, 'docs/readme.txt');
      assert.equal(entry.size, body.length);
      assert.equal(entry.sha256, createHash('sha256').update(body).digest('hex'));
      assert.ok(!Number.isNaN(Date.parse(entry.modified_at)));

      const delRes = await fetch(`http://127.0.0.1:${port}/blobs/docs/readme.txt`, { method: 'DELETE' });
      assert.equal(delRes.status, 204);
      assert.equal(await delRes.text(), '');
      const goneRes = await fetch(`http://127.0.0.1:${port}/blobs/docs/readme.txt`);
      assert.equal(goneRes.status, 404);
      await goneRes.body?.cancel();
      assert.deepEqual(await (await fetch(`http://127.0.0.1:${port}/blobs`)).json(), []);
      const againRes = await fetch(`http://127.0.0.1:${port}/blobs/docs/readme.txt`, { method: 'DELETE' });
      assert.equal(againRes.status, 404);
      await againRes.body?.cancel();
    } finally {
      await stop(proc);
    }
  });

  it('exits cleanly with code 0 on SIGTERM', async () => {
    const port = await freePort();
    const proc = startServer(['--data-dir', path.join(tmp, 'sigterm'), '--port', String(port)]);
    await waitForHealthy(port, proc);
    const { code } = await stop(proc);
    assert.equal(code, 0);
  });

  it('discards uploads left behind by an earlier run at startup', async () => {
    const dataDir = path.join(tmp, 'stale-uploads');
    await fs.mkdir(path.join(dataDir, 'tmp'), { recursive: true });
    await fs.writeFile(path.join(dataDir, 'tmp', 'deadbeef.part'), 'half an upload');
    const port = await freePort();
    const proc = startServer(['--data-dir', dataDir, '--port', String(port)]);
    try {
      await waitForHealthy(port, proc);
      assert.deepEqual(await fs.readdir(path.join(dataDir, 'tmp')), []);
      assert.deepEqual(await (await fetch(`http://127.0.0.1:${port}/blobs`)).json(), []);
    } finally {
      await stop(proc);
    }
  });

  it('leaves no temp file and no blob when stopped in the middle of an upload', async () => {
    const dataDir = path.join(tmp, 'stopped-mid-upload');
    const port = await freePort();
    const proc = startServer(['--data-dir', dataDir, '--port', String(port)]);
    await waitForHealthy(port, proc);

    // A client that never finishes its body, so the server has to give up on it.
    const socket = net.connect(port, '127.0.0.1');
    socket.on('error', () => {});
    await new Promise((resolve) => socket.once('connect', resolve));
    socket.write(`PUT /blobs/unfinished HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n${'z'.repeat(4096)}`);
    try {
      const deadline = Date.now() + 5000;
      while ((await fs.readdir(path.join(dataDir, 'tmp'))).length === 0) {
        assert.ok(Date.now() < deadline, 'the upload never reached the disk');
        await new Promise((r) => setTimeout(r, 10));
      }
      const { code } = await stop(proc);
      assert.equal(code, 0);
      assert.deepEqual(await fs.readdir(path.join(dataDir, 'tmp')).catch(() => []), []);
      assert.deepEqual(await fs.readdir(path.join(dataDir, 'blobs')), []);
    } finally {
      socket.destroy();
      await stop(proc);
    }
  });

  it('exits with code 2 and a message when --data-dir is missing', async () => {
    const proc = startServer(['--port', '8080']);
    const { code } = await proc.exited;
    assert.equal(code, 2);
    assert.match(proc.output().stderr, /data directory is required/);
  });

  it('exits with code 2 on an invalid port', async () => {
    const proc = startServer(['--data-dir', tmp, '--port', 'not-a-port']);
    const { code } = await proc.exited;
    assert.equal(code, 2);
    assert.match(proc.output().stderr, /invalid port/);
  });

  it('fails when the data directory path is a regular file', async () => {
    const file = path.join(tmp, 'regular-file');
    await fs.writeFile(file, 'x');
    const proc = startServer(['--data-dir', file, '--port', String(await freePort())]);
    const { code } = await proc.exited;
    assert.equal(code, 1);
    assert.match(proc.output().stderr, /data directory .* is not usable/);
  });

  it('fails when the port is already in use', async () => {
    const blocker = net.createServer();
    await new Promise((resolve) => blocker.listen(0, resolve));
    try {
      const port = blocker.address().port;
      const proc = startServer(['--data-dir', tmp, '--port', String(port)]);
      const { code } = await proc.exited;
      assert.equal(code, 1);
      assert.match(proc.output().stderr, /cannot listen on port/);
    } finally {
      await new Promise((resolve) => blocker.close(resolve));
    }
  });

  it('prints usage on --help', async () => {
    const proc = startServer(['--help']);
    const { code } = await proc.exited;
    assert.equal(code, 0);
    assert.match(proc.output().stdout, /Usage: syncbox-server/);
  });
});
