'use strict';

// End-to-end tests of the actual CLI entry point (src/cli.js) as a
// subprocess, rather than calling the command modules' run() directly - the
// spec's error-handling requirements are about what the CLI prints to
// stderr and which exit code it returns, which only the process boundary
// actually exercises.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const http = require('node:http');
const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const CLI_PATH = path.join(__dirname, '..', 'src', 'cli.js');

// Safety net against the very hang this ticket is about: if the CLI process
// doesn't exit on its own well within this window, execFile kills it and we
// assert on that below rather than letting the test itself hang forever.
const HANG_GUARD_MS = 5000;

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-cli-test-'));
}

function runCli(args, { env = {} } = {}) {
  return new Promise((resolve) => {
    execFile(
      process.execPath,
      [CLI_PATH, ...args],
      { timeout: HANG_GUARD_MS, env: { ...process.env, ...env } },
      (err, stdout, stderr) => {
        resolve({
          code: err ? (typeof err.code === 'number' ? err.code : 1) : 0,
          hung: !!(err && err.killed),
          stdout,
          stderr,
        });
      }
    );
  });
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

test('cli push exits non-zero with a clear stderr message when the server refuses the connection, and does not hang', async () => {
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  const result = await runCli(['push', dir, '--server', 'http://127.0.0.1:1']);

  assert.equal(result.hung, false);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /connection refused/i);
});

test('cli push exits non-zero with a clear stderr message when the server accepts the connection but never responds, and does not hang', async (t) => {
  const server = net.createServer((socket) => {
    t.after(() => socket.destroy());
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello');

  const result = await runCli(['push', dir, '--server', `http://127.0.0.1:${port}`], {
    env: { SYNCBOX_TEST_ONLY_REQUEST_TIMEOUT_MS: '300' },
  });

  assert.equal(result.hung, false);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /timed out/i);
});

test('cli push reports a per-file failure summary on stderr and exits non-zero, while still uploading the other files', async (t) => {
  const stored = new Map();
  const server = http.createServer((req, res) => {
    const pathname = req.url.split('?')[0];
    if (req.method === 'GET' && pathname === '/blobs') {
      const list = [...stored.entries()].map(([key, buffer]) => ({
        key,
        size: buffer.length,
        sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
        modified_at: new Date(0).toISOString(),
      }));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(list));
      return;
    }
    const match = pathname.match(/^\/blobs\/(.+)$/);
    if (match && req.method === 'PUT') {
      const key = decodeURIComponent(match[1]);
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        if (key === 'bad.txt') {
          res.writeHead(500, { 'Content-Type': 'text/plain' });
          res.end('internal error');
          return;
        }
        const buffer = Buffer.concat(chunks);
        stored.set(key, buffer);
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ key, sha256: crypto.createHash('sha256').update(buffer).digest('hex'), size: buffer.length }));
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'good.txt'), 'hello');
  fs.writeFileSync(path.join(dir, 'bad.txt'), 'will fail');

  const result = await runCli(['push', dir, '--server', `http://127.0.0.1:${port}`]);

  assert.notEqual(result.code, 0);
  assert.match(result.stdout, /uploaded good\.txt/);
  assert.match(result.stderr, /bad\.txt/);
  assert.match(result.stderr, /status 500/);
  assert.equal(stored.get('good.txt').toString(), 'hello');
});

test('cli pull reports a per-file failure summary on stderr and exits non-zero, while still downloading the other files', async (t) => {
  const store = new Map([
    ['good.txt', Buffer.from('hello')],
    ['bad.txt', Buffer.from('will fail')],
  ]);
  const server = http.createServer((req, res) => {
    const pathname = req.url.split('?')[0];
    if (req.method === 'GET' && pathname === '/blobs') {
      const list = [...store.entries()].map(([key, buffer]) => ({
        key,
        size: buffer.length,
        sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
        modified_at: new Date(0).toISOString(),
      }));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(list));
      return;
    }
    const match = pathname.match(/^\/blobs\/(.+)$/);
    if (match && req.method === 'GET') {
      const key = decodeURIComponent(match[1]);
      if (key === 'bad.txt') {
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end('internal error');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(store.get(key));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  const port = await listen(server);
  t.after(() => server.close());

  const dir = tempDir();

  const result = await runCli(['pull', dir, '--server', `http://127.0.0.1:${port}`]);

  assert.notEqual(result.code, 0);
  assert.match(result.stdout, /downloaded good\.txt/);
  assert.match(result.stderr, /bad\.txt/);
  assert.match(result.stderr, /status 500/);
  assert.equal(fs.readFileSync(path.join(dir, 'good.txt'), 'utf8'), 'hello');
  assert.equal(fs.existsSync(path.join(dir, 'bad.txt')), false);
});
