'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveConfig } = require('../src/config');

test('reads <dir> and --server from argv', () => {
  const config = resolveConfig(['./mydir', '--server', 'http://localhost:8080'], {});
  assert.deepEqual(config, { dir: './mydir', serverUrl: 'http://localhost:8080' });
});

test('falls back to SYNCBOX_SERVER when --server is not given', () => {
  const config = resolveConfig(['./mydir'], { SYNCBOX_SERVER: 'http://localhost:9090' });
  assert.deepEqual(config, { dir: './mydir', serverUrl: 'http://localhost:9090' });
});

test('--server takes precedence over SYNCBOX_SERVER', () => {
  const config = resolveConfig(
    ['./mydir', '--server', 'http://argv:8080'],
    { SYNCBOX_SERVER: 'http://env:9090' }
  );
  assert.equal(config.serverUrl, 'http://argv:8080');
});

test('accepts --server before the <dir> positional', () => {
  const config = resolveConfig(['--server', 'http://localhost:8080', './mydir'], {});
  assert.deepEqual(config, { dir: './mydir', serverUrl: 'http://localhost:8080' });
});

test('throws when <dir> is missing', () => {
  assert.throws(() => resolveConfig(['--server', 'http://localhost:8080'], {}), /missing required argument <dir>/);
});

test('throws when --server is missing everywhere', () => {
  assert.throws(() => resolveConfig(['./mydir'], {}), /--server is required/);
});

test('throws on an unexpected second positional argument', () => {
  assert.throws(
    () => resolveConfig(['./mydir', './other', '--server', 'http://localhost:8080'], {}),
    /unexpected argument/
  );
});

test('throws on an unknown flag', () => {
  assert.throws(() => resolveConfig(['./mydir', '--bogus', 'x'], {}), /unknown argument/);
});

test('throws when --server has no value', () => {
  assert.throws(() => resolveConfig(['./mydir', '--server'], {}), /--server requires a value/);
});
