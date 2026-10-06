// End-to-end tests of the `syncbox` executable: spawns bin/syncbox as a real
// process against a server running in-process on loopback.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import { createServer } from '../src/server.js';

const SYNCBOX = fileURLToPath(new URL('../bin/syncbox', import.meta.url));

// Environment without any SYNCBOX_* variables inherited from the test runner.
const CLEAN_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('SYNCBOX_')));

function run(args, env = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(SYNCBOX, args, { env: { ...CLEAN_ENV, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
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

  for (const command of ['pull', 'status', 'sync']) {
    it(`${command} says it is not implemented yet`, async () => {
      const dir = await makeDir(`not-implemented-${command}`, {});
      await fs.mkdir(dir, { recursive: true });
      const { code, stdout, stderr } = await run([command, dir, '--server', serverUrl]);
      assert.equal(code, 1);
      assert.equal(stdout, '');
      assert.equal(stderr, `syncbox: the ${command} command is not implemented yet; only push is available\n`);
    });
  }

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
