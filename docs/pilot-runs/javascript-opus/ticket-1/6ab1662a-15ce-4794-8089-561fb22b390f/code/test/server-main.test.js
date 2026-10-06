// End-to-end tests of the server entry point: spawns `node src/server-main.js`
// as a real process and talks to it over HTTP.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
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

  it('exits cleanly with code 0 on SIGTERM', async () => {
    const port = await freePort();
    const proc = startServer(['--data-dir', path.join(tmp, 'sigterm'), '--port', String(port)]);
    await waitForHealthy(port, proc);
    const { code } = await stop(proc);
    assert.equal(code, 0);
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
