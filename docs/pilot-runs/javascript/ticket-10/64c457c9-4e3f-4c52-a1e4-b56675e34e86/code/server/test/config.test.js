'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveConfig } = require('../src/config');

test('reads --data-dir and --port from argv', () => {
  const config = resolveConfig(['--data-dir', '/tmp/data', '--port', '9090'], {});
  assert.deepEqual(config, { dataDir: '/tmp/data', port: 9090 });
});

test('defaults port to 8080 when not given', () => {
  const config = resolveConfig(['--data-dir', '/tmp/data'], {});
  assert.equal(config.port, 8080);
});

test('falls back to SYNCBOX_DATA_DIR and SYNCBOX_PORT env vars', () => {
  const config = resolveConfig([], { SYNCBOX_DATA_DIR: '/tmp/env-data', SYNCBOX_PORT: '9999' });
  assert.deepEqual(config, { dataDir: '/tmp/env-data', port: 9999 });
});

test('argv flags take precedence over env vars', () => {
  const config = resolveConfig(
    ['--data-dir', '/tmp/argv-data', '--port', '7070'],
    { SYNCBOX_DATA_DIR: '/tmp/env-data', SYNCBOX_PORT: '9999' }
  );
  assert.deepEqual(config, { dataDir: '/tmp/argv-data', port: 7070 });
});

test('throws when --data-dir is missing everywhere', () => {
  assert.throws(() => resolveConfig([], {}), /--data-dir is required/);
});

test('throws on a non-numeric port', () => {
  assert.throws(() => resolveConfig(['--data-dir', '/tmp/data', '--port', 'abc'], {}), /invalid port/);
});

test('throws on an unknown argument', () => {
  assert.throws(() => resolveConfig(['--bogus', 'x'], {}), /unknown argument/);
});
