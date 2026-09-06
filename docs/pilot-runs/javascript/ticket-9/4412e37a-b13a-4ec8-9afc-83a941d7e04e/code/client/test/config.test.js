'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseArgs } = require('../src/config');

test('parseArgs accepts push with --server flag', () => {
  const args = parseArgs(['push', '/data', '--server', 'http://127.0.0.1:8080'], {});
  assert.deepEqual(args, { command: 'push', dir: '/data', server: 'http://127.0.0.1:8080' });
});

test('parseArgs strips a trailing slash from --server', () => {
  const args = parseArgs(['push', '/data', '--server', 'http://127.0.0.1:8080/'], {});
  assert.equal(args.server, 'http://127.0.0.1:8080');
});

test('parseArgs falls back to SYNCBOX_SERVER env var', () => {
  const args = parseArgs(['push', '/data'], { SYNCBOX_SERVER: 'http://example.test' });
  assert.equal(args.server, 'http://example.test');
});

test('--server flag takes precedence over the env var', () => {
  const args = parseArgs(['push', '/data', '--server', 'http://from-flag'], {
    SYNCBOX_SERVER: 'http://from-env',
  });
  assert.equal(args.server, 'http://from-flag');
});

test('parseArgs accepts pull/sync/status as valid commands', () => {
  for (const command of ['pull', 'sync', 'status']) {
    const args = parseArgs([command, '/data', '--server', 'http://x'], {});
    assert.equal(args.command, command);
  }
});

test('parseArgs rejects an unknown command', () => {
  assert.throws(() => parseArgs(['bogus', '/data', '--server', 'http://x'], {}), /unknown command/);
});

test('parseArgs requires <dir>', () => {
  assert.throws(() => parseArgs(['push'], { SYNCBOX_SERVER: 'http://x' }), /<dir> is required/);
});

test('parseArgs requires --server when no env var is set', () => {
  assert.throws(() => parseArgs(['push', '/data'], {}), /--server is required/);
});

test('parseArgs rejects unknown trailing arguments', () => {
  assert.throws(
    () => parseArgs(['push', '/data', '--server', 'http://x', '--bogus'], {}),
    /unknown argument/
  );
});
