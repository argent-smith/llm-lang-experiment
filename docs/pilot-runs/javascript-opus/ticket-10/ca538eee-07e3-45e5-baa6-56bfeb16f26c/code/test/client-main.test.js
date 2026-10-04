// End-to-end tests of the `syncbox` executable: spawns bin/syncbox as a real
// process against a server running in-process on loopback.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import { createServer } from '../src/server.js';

const SYNCBOX = fileURLToPath(new URL('../bin/syncbox', import.meta.url));

// Environment without any SYNCBOX_* variables inherited from the test runner.
const CLEAN_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('SYNCBOX_')));

function run(args, env = {}, onSpawn = () => {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(SYNCBOX, args, { env: { ...CLEAN_ENV, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
    onSpawn(child);
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', reject);
    child.on('exit', (code) => resolve({ code, stdout, stderr }));
  });
}

const sha256 = (data) => createHash('sha256').update(data).digest('hex');

describe('syncbox CLI', () => {
  let tmp;
  let server;
  let serverUrl;
  let puts;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-cli-'));
    server = createServer({ dataDir: path.join(tmp, 'data') });
    puts = 0;
    server.on('request', (req) => req.method === 'PUT' && puts++);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    serverUrl = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(tmp, { recursive: true, force: true });
  });

  async function makeDir(name, files) {
    const dir = path.join(tmp, name);
    for (const [rel, content] of Object.entries(files)) {
      await fs.mkdir(path.dirname(path.join(dir, rel)), { recursive: true });
      await fs.writeFile(path.join(dir, rel), content);
    }
    return dir;
  }

  it('push uploads the directory and reports what it did', async () => {
    const dir = await makeDir('push-basic', { 'cli/one.txt': '1', 'cli/sub/two.txt': '22' });
    const first = await run(['push', dir, '--server', serverUrl]);
    assert.equal(first.code, 0, first.stderr);
    assert.equal(first.stdout, 'uploaded cli/one.txt\nuploaded cli/sub/two.txt\npush: 2 uploaded, 0 already up to date\n');
    assert.equal(first.stderr, '');

    const blobs = await (await fetch(`${serverUrl}/blobs`)).json();
    assert.deepEqual(
      blobs.filter((b) => b.key.startsWith('cli/')).map((b) => [b.key, b.sha256]),
      [['cli/one.txt', sha256('1')], ['cli/sub/two.txt', sha256('22')]],
    );

    const putsBefore = puts;
    const second = await run(['push', dir, '--server', serverUrl]);
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, 'push: 0 uploaded, 2 already up to date\n');
    assert.equal(puts, putsBefore);
  });

  it('push takes the server from SYNCBOX_SERVER', async () => {
    const dir = await makeDir('push-env', { 'env.txt': 'from env' });
    const { code, stdout, stderr } = await run(['push', dir], { SYNCBOX_SERVER: serverUrl });
    assert.equal(code, 0, stderr);
    assert.match(stdout, /^uploaded env\.txt$/m);
  });

  it('--server overrides SYNCBOX_SERVER', async () => {
    const dir = await makeDir('push-override', { 'override.txt': 'x' });
    const { code, stderr } = await run(['push', dir, `--server=${serverUrl}`], { SYNCBOX_SERVER: 'http://127.0.0.1:1' });
    assert.equal(code, 0, stderr);
  });

  it('push reports skipped files on stderr', async () => {
    const dir = await makeDir('push-skip', { 'kept.txt': 'k' });
    await fs.symlink('kept.txt', path.join(dir, 'link'));
    const { code, stdout, stderr } = await run(['push', dir, '--server', serverUrl]);
    assert.equal(code, 0, stderr);
    assert.match(stdout, /^uploaded kept\.txt$/m);
    assert.equal(stderr, 'syncbox: skipping link: symbolic link\n');
  });

  it('exits with code 1 and a message when the server is unreachable', async () => {
    const probe = net.createServer();
    const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
    await new Promise((resolve) => probe.close(resolve));

    const dir = await makeDir('push-unreachable', { 'a.txt': 'a' });
    const { code, stdout, stderr } = await run(['push', dir, '--server', `http://127.0.0.1:${port}`]);
    assert.equal(code, 1);
    assert.equal(stdout, '');
    assert.match(stderr, /^syncbox: cannot reach server http:\/\/127\.0\.0\.1:\d+\/: .*ECONNREFUSED/);
  });

  it('exits with code 1 when the directory does not exist', async () => {
    const { code, stderr } = await run(['push', path.join(tmp, 'no-such-dir'), '--server', serverUrl]);
    assert.equal(code, 1);
    assert.match(stderr, /^syncbox: ENOENT: no such file or directory/);
  });

  it('exits with code 2 and usage when --server is missing', async () => {
    const { code, stderr } = await run(['push', tmp]);
    assert.equal(code, 2);
    assert.match(stderr, /server URL is required: pass --server <url> or set SYNCBOX_SERVER/);
    assert.match(stderr, /Usage: syncbox/);
  });

  it('exits with code 2 on an unknown command', async () => {
    const { code, stderr } = await run(['upload', tmp, '--server', serverUrl]);
    assert.equal(code, 2);
    assert.match(stderr, /unknown command: upload/);
  });

  it('prints usage on --help', async () => {
    const { code, stdout } = await run(['--help']);
    assert.equal(code, 0);
    assert.match(stdout, /^Usage: syncbox <command> <dir> --server <url>/);
  });
});

describe('syncbox pull CLI', () => {
  let tmp;
  let server;
  let serverUrl;
  let gets;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-cli-pull-'));
    server = createServer({ dataDir: path.join(tmp, 'data') });
    gets = 0;
    server.on('request', (req) => req.method === 'GET' && req.url.startsWith('/blobs/') && gets++);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    serverUrl = `http://127.0.0.1:${server.address().port}`;
    for (const [key, content] of [['one.txt', '1'], ['sub/two.txt', '22']]) {
      await fetch(`${serverUrl}/blobs/${key}`, { method: 'PUT', body: content });
    }
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(tmp, { recursive: true, force: true });
  });

  it('pull downloads the blobs and reports what it did', async () => {
    const dir = path.join(tmp, 'pull-basic');
    await fs.mkdir(dir);
    const first = await run(['pull', dir, '--server', serverUrl]);
    assert.equal(first.code, 0, first.stderr);
    assert.equal(first.stdout, 'downloaded one.txt\ndownloaded sub/two.txt\npull: 2 downloaded, 0 already up to date\n');
    assert.equal(first.stderr, '');
    assert.equal(await fs.readFile(path.join(dir, 'one.txt'), 'utf8'), '1');
    assert.equal(await fs.readFile(path.join(dir, 'sub', 'two.txt'), 'utf8'), '22');

    const getsBefore = gets;
    const second = await run(['pull', dir, '--server', serverUrl]);
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, 'pull: 0 downloaded, 2 already up to date\n');
    assert.equal(gets, getsBefore);
  });

  it('pull takes the server from SYNCBOX_SERVER and creates a missing directory', async () => {
    const dir = path.join(tmp, 'pull-env', 'new');
    const { code, stdout, stderr } = await run(['pull', dir], { SYNCBOX_SERVER: serverUrl });
    assert.equal(code, 0, stderr);
    assert.match(stdout, /^pull: 2 downloaded, 0 already up to date$/m);
    assert.equal(await fs.readFile(path.join(dir, 'sub', 'two.txt'), 'utf8'), '22');
  });

  it('pull reports skipped blobs on stderr', async () => {
    const dir = path.join(tmp, 'pull-skip');
    await fs.mkdir(dir);
    await fs.symlink('elsewhere', path.join(dir, 'sub'));
    const { code, stdout, stderr } = await run(['pull', dir, '--server', serverUrl]);
    assert.equal(code, 0, stderr);
    assert.equal(stdout, 'downloaded one.txt\npull: 1 downloaded, 0 already up to date\n');
    assert.equal(stderr, 'syncbox: skipping sub/two.txt: sub is a symbolic link\n');
  });

  it('pull exits with code 1 and a message when a file is in the way', async () => {
    const dir = path.join(tmp, 'pull-conflict');
    await fs.mkdir(path.join(dir, 'one.txt'), { recursive: true });
    const { code, stderr } = await run(['pull', dir, '--server', serverUrl]);
    assert.equal(code, 1);
    assert.equal(stderr, 'syncbox: cannot write one.txt: a directory is in the way\n');
  });

  it('pull exits with code 1 and a message when the server is unreachable', async () => {
    const probe = net.createServer();
    const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
    await new Promise((resolve) => probe.close(resolve));

    const dir = path.join(tmp, 'pull-unreachable');
    await fs.mkdir(dir);
    const { code, stdout, stderr } = await run(['pull', dir, '--server', `http://127.0.0.1:${port}`]);
    assert.equal(code, 1);
    assert.equal(stdout, '');
    assert.match(stderr, /^syncbox: cannot reach server http:\/\/127\.0\.0\.1:\d+\/: .*ECONNREFUSED/);
  });

  it('pull stops on SIGINT, leaving no partial file behind', async () => {
    // Lists one blob and sends half of it, then stalls.
    let stalled;
    const isStalled = new Promise((resolve) => (stalled = resolve));
    const fake = http.createServer((req, res) => {
      if (req.url === '/blobs') {
        res.end(JSON.stringify([{ key: 'slow.bin', sha256: sha256('x'.repeat(1000)), size: 1000, modified_at: new Date().toISOString() }]));
        return;
      }
      res.writeHead(200, { 'Content-Length': '1000' });
      res.write('x'.repeat(500), stalled);
    });
    await new Promise((resolve) => fake.listen(0, '127.0.0.1', resolve));
    const dir = path.join(tmp, 'pull-interrupted');
    await fs.mkdir(dir);
    try {
      const { code, stdout, stderr } = await run(
        ['pull', dir, '--server', `http://127.0.0.1:${fake.address().port}`],
        {},
        (child) => isStalled.then(() => setTimeout(() => child.kill('SIGINT'), 100)),
      );
      assert.equal(code, 130);
      assert.equal(stdout, '');
      assert.equal(stderr, 'syncbox: interrupted\n');
      assert.deepEqual(await fs.readdir(dir), []);
    } finally {
      fake.closeAllConnections();
      await new Promise((resolve) => fake.close(resolve));
    }
  });
});

describe('syncbox status CLI', () => {
  let tmp;
  let dataDir;
  let server;
  let serverUrl;
  let requests;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-cli-status-'));
    dataDir = path.join(tmp, 'data');
    server = createServer({ dataDir });
    requests = [];
    server.on('request', (req) => requests.push(`${req.method} ${req.url}`));
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    serverUrl = `http://127.0.0.1:${server.address().port}`;
    for (const [key, content] of [['same.txt', 'same'], ['changed.txt', 'server version'], ['remote/only.txt', 'r']]) {
      await fetch(`${serverUrl}/blobs/${key}`, { method: 'PUT', body: content });
    }
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(tmp, { recursive: true, force: true });
  });

  async function makeDir(name, files) {
    const dir = path.join(tmp, name);
    await fs.mkdir(dir, { recursive: true });
    for (const [rel, content] of Object.entries(files)) {
      await fs.mkdir(path.dirname(path.join(dir, rel)), { recursive: true });
      await fs.writeFile(path.join(dir, rel), content);
    }
    return dir;
  }

  /** Every file under `root` with its contents and mtime. */
  async function snapshot(root) {
    const out = {};
    for (const entry of await fs.readdir(root, { recursive: true, withFileTypes: true })) {
      const full = path.join(entry.path, entry.name);
      const stat = await fs.lstat(full);
      out[path.relative(root, full)] = `${entry.isFile() ? await fs.readFile(full, 'latin1') : '<dir>'} ${stat.mtimeMs}`;
    }
    return out;
  }

  it('reports uploads and downloads by direction, exits 0 and changes nothing', async () => {
    const dir = await makeDir('status-diverged', { 'same.txt': 'same', 'changed.txt': 'local version', 'local/only.txt': 'l' });
    const localBefore = await snapshot(dir);
    const serverBefore = await snapshot(dataDir);
    requests.length = 0;

    const { code, stdout, stderr } = await run(['status', dir, '--server', serverUrl]);
    assert.equal(code, 0, stderr);
    assert.equal(stderr, '');
    assert.equal(
      stdout,
      [
        'Would upload to the server (push): 2 files',
        '  differs  changed.txt',
        '  new      local/only.txt',
        'Would download from the server (pull): 2 files',
        '  differs  changed.txt',
        '  new      remote/only.txt',
        "1 file differs on both sides: push would replace the server's copy, pull the local one.",
        'status: 2 to upload, 2 to download, 1 up to date',
        '',
      ].join('\n'),
    );
    assert.deepEqual(requests, ['GET /blobs']);
    assert.deepEqual(await snapshot(dir), localBefore);
    assert.deepEqual(await snapshot(dataDir), serverBefore);
  });

  it('says everything is up to date when nothing differs, exiting 0', async () => {
    const dir = await makeDir('status-in-sync', { 'same.txt': 'same', 'changed.txt': 'server version', 'remote/only.txt': 'r' });
    const { code, stdout, stderr } = await run(['status', dir, '--server', serverUrl]);
    assert.equal(code, 0, stderr);
    assert.equal(stdout, 'Up to date: nothing to upload or download.\nstatus: 0 to upload, 0 to download, 3 up to date\n');
  });

  it('takes the server from SYNCBOX_SERVER', async () => {
    const dir = await makeDir('status-env', { 'env.txt': 'from env' });
    const { code, stdout, stderr } = await run(['status', dir], { SYNCBOX_SERVER: serverUrl });
    assert.equal(code, 0, stderr);
    assert.match(stdout, /^  new {6}env\.txt$/m);
    assert.match(stdout, /^status: 1 to upload, 3 to download, 0 up to date$/m);
  });

  it('reports skipped files on stderr', async () => {
    const dir = await makeDir('status-skip', { 'same.txt': 'same', 'changed.txt': 'server version', 'remote/only.txt': 'r' });
    await fs.symlink('same.txt', path.join(dir, 'link'));
    const { code, stdout, stderr } = await run(['status', dir, '--server', serverUrl]);
    assert.equal(code, 0, stderr);
    assert.match(stdout, /^Up to date: /);
    assert.equal(stderr, 'syncbox: skipping link: symbolic link\n');
  });

  it('exits with code 1 and a message when the server is unreachable', async () => {
    const probe = net.createServer();
    const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
    await new Promise((resolve) => probe.close(resolve));

    const dir = await makeDir('status-unreachable', { 'a.txt': 'a' });
    const { code, stdout, stderr } = await run(['status', dir, '--server', `http://127.0.0.1:${port}`]);
    assert.equal(code, 1);
    assert.equal(stdout, '');
    assert.match(stderr, /^syncbox: cannot reach server http:\/\/127\.0\.0\.1:\d+\/: .*ECONNREFUSED/);
  });

  it('exits with code 1 when the directory does not exist, creating nothing', async () => {
    const missing = path.join(tmp, 'status-missing');
    const { code, stderr } = await run(['status', missing, '--server', serverUrl]);
    assert.equal(code, 1);
    assert.match(stderr, /^syncbox: ENOENT: no such file or directory/);
    await assert.rejects(fs.stat(missing), { code: 'ENOENT' });
  });

  it('exits with code 2 and usage when --server is missing', async () => {
    const { code, stderr } = await run(['status', tmp]);
    assert.equal(code, 2);
    assert.match(stderr, /server URL is required: pass --server <url> or set SYNCBOX_SERVER/);
  });
});

describe('syncbox sync CLI', () => {
  let tmp;
  let dataDir;
  let stateDir;
  let server;
  let serverUrl;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-cli-sync-'));
    dataDir = path.join(tmp, 'data');
    stateDir = path.join(tmp, 'state');
    server = createServer({ dataDir });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    serverUrl = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(tmp, { recursive: true, force: true });
  });

  async function makeDir(name, files) {
    const dir = path.join(tmp, name);
    await fs.mkdir(dir, { recursive: true });
    for (const [rel, content] of Object.entries(files)) {
      await fs.mkdir(path.dirname(path.join(dir, rel)), { recursive: true });
      await fs.writeFile(path.join(dir, rel), content);
    }
    return dir;
  }

  async function serverText(key) {
    const res = await fetch(`${serverUrl}/blobs/${key}`);
    assert.equal(res.status, 200, key);
    return res.text();
  }

  it('transfers both ways, reports what it did and exits 0', async () => {
    await fetch(`${serverUrl}/blobs/basic/remote.txt`, { method: 'PUT', body: 'from server' });
    const dir = await makeDir('sync-basic', { 'basic/local.txt': 'from local' });

    const first = await run(['sync', dir, '--server', serverUrl], { SYNCBOX_STATE_DIR: stateDir });
    assert.equal(first.code, 0, first.stderr);
    assert.equal(first.stderr, '');
    assert.equal(first.stdout, 'uploaded basic/local.txt\ndownloaded basic/remote.txt\nsync: 1 uploaded, 1 downloaded, 0 already up to date\n');
    assert.equal(await serverText('basic/local.txt'), 'from local');
    assert.equal(await fs.readFile(path.join(dir, 'basic', 'remote.txt'), 'utf8'), 'from server');
    // State lives in SYNCBOX_STATE_DIR, not in the synced directory.
    assert.equal((await fs.readdir(stateDir)).length, 1);
    assert.deepEqual((await fs.readdir(dir, { recursive: true })).sort(), ['basic', 'basic/local.txt', 'basic/remote.txt']);

    const second = await run(['sync', dir, '--server', serverUrl], { SYNCBOX_STATE_DIR: stateDir });
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, 'sync: 0 uploaded, 0 downloaded, 2 already up to date\n');
  });

  it('settles a file changed on both sides by modification time, saying so', async () => {
    const dir = await makeDir('sync-conflict', { 'conflict/doc.txt': 'original' });
    const env = { SYNCBOX_STATE_DIR: stateDir };
    assert.equal((await run(['sync', dir, '--server', serverUrl], env)).code, 0);

    await fs.writeFile(path.join(dir, 'conflict', 'doc.txt'), 'local version');
    await fetch(`${serverUrl}/blobs/conflict/doc.txt`, { method: 'PUT', body: 'server version' });
    const T = new Date('2024-05-06T07:08:09Z');
    await fs.utimes(path.join(dir, 'conflict', 'doc.txt'), T, T);
    await fs.utimes(path.join(dataDir, 'blobs', 'conflict', 'doc.txt'), new Date(T.getTime() + 1000), new Date(T.getTime() + 1000));

    const { code, stdout, stderr } = await run(['sync', dir, '--server', serverUrl], env);
    assert.equal(code, 0, stderr);
    // Blobs other tests put on the shared server are up to date here as well.
    assert.match(
      stdout,
      /^downloaded conflict\/doc\.txt \(changed on both sides, server copy is newer\)\nsync: 0 uploaded, 1 downloaded, \d+ already up to date, 1 conflict resolved\n$/,
    );
    assert.equal(await fs.readFile(path.join(dir, 'conflict', 'doc.txt'), 'utf8'), 'server version');
  });

  it('takes the server from SYNCBOX_SERVER', async () => {
    const dir = await makeDir('sync-env', { 'env/only-local.txt': 'env' });
    const { code, stdout, stderr } = await run(['sync', dir], { SYNCBOX_SERVER: serverUrl, SYNCBOX_STATE_DIR: stateDir });
    assert.equal(code, 0, stderr);
    assert.match(stdout, /^uploaded env\/only-local\.txt$/m);
    assert.equal(await serverText('env/only-local.txt'), 'env');
  });

  it('exits with code 1 and a message when the server is unreachable', async () => {
    const probe = net.createServer();
    const port = await new Promise((resolve) => probe.listen(0, '127.0.0.1', () => resolve(probe.address().port)));
    await new Promise((resolve) => probe.close(resolve));

    const dir = await makeDir('sync-unreachable', { 'a.txt': 'a' });
    const { code, stdout, stderr } = await run(['sync', dir, '--server', `http://127.0.0.1:${port}`], { SYNCBOX_STATE_DIR: stateDir });
    assert.equal(code, 1);
    assert.equal(stdout, '');
    assert.match(stderr, /^syncbox: cannot reach server http:\/\/127\.0\.0\.1:\d+\/: .*ECONNREFUSED/);
  });

  it('exits with code 1 when the directory does not exist', async () => {
    const { code, stderr } = await run(['sync', path.join(tmp, 'sync-missing'), '--server', serverUrl], { SYNCBOX_STATE_DIR: stateDir });
    assert.equal(code, 1);
    assert.match(stderr, /^syncbox: ENOENT: no such file or directory/);
  });

  it('exits with code 2 and usage when --server is missing', async () => {
    const { code, stderr } = await run(['sync', tmp]);
    assert.equal(code, 2);
    assert.match(stderr, /server URL is required: pass --server <url> or set SYNCBOX_SERVER/);
  });
});
