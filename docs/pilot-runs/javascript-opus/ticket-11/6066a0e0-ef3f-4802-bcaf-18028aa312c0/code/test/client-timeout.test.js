// The `syncbox` executable against a server that accepts connections but never
// answers: it must give up by itself, with its default timeout, and exit.
// In a file of its own, since it takes as long as that timeout; test files
// run in parallel.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import { RESPONSE_TIMEOUT_MS } from '../src/client.js';

const SYNCBOX = fileURLToPath(new URL('../bin/syncbox', import.meta.url));
const CLEAN_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('SYNCBOX_')));

describe('syncbox CLI against a server that does not answer', () => {
  let tmp;
  let server;
  let serverUrl;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-cli-timeout-'));
    await fs.writeFile(path.join(tmp, 'a.txt'), 'a');
    // Accepts every connection and request, and answers none.
    server = http.createServer(() => {});
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    serverUrl = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(tmp, { recursive: true, force: true });
  });

  it('gives up after its default timeout, says so and exits 1', { timeout: RESPONSE_TIMEOUT_MS + 30_000 }, async () => {
    const started = performance.now();
    const { code, stdout, stderr } = await new Promise((resolve, reject) => {
      const child = spawn(SYNCBOX, ['push', tmp, '--server', serverUrl], { env: CLEAN_ENV, stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      let err = '';
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (err += d));
      child.on('error', reject);
      child.on('exit', (exitCode) => resolve({ code: exitCode, stdout: out, stderr: err }));
    });
    const elapsed = performance.now() - started;

    assert.equal(code, 1);
    assert.equal(stdout, '');
    assert.equal(stderr, `syncbox: GET /blobs: timed out: no response from the server within ${RESPONSE_TIMEOUT_MS / 1000} s\n`);
    assert.ok(elapsed >= RESPONSE_TIMEOUT_MS - 1000, `gave up after ${elapsed} ms`);
    assert.ok(elapsed < RESPONSE_TIMEOUT_MS + 10_000, `gave up after ${elapsed} ms`);
  });
});
