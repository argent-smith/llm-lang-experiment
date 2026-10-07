import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { ConfigError, DEFAULT_PORT, parseConfig } from '../src/config.js';

describe('parseConfig', () => {
  it('reads --data-dir and --port flags', () => {
    assert.deepEqual(parseConfig(['--data-dir', '/srv/data', '--port', '9000'], {}), {
      help: false,
      dataDir: '/srv/data',
      port: 9000,
    });
  });

  it('accepts --flag=value form', () => {
    assert.deepEqual(parseConfig(['--data-dir=/srv/data', '--port=9000'], {}), {
      help: false,
      dataDir: '/srv/data',
      port: 9000,
    });
  });

  it('defaults port to 8080', () => {
    assert.equal(DEFAULT_PORT, 8080);
    assert.equal(parseConfig(['--data-dir', '/srv/data'], {}).port, 8080);
  });

  it('falls back to SYNCBOX_DATA_DIR and SYNCBOX_PORT', () => {
    const env = { SYNCBOX_DATA_DIR: '/env/data', SYNCBOX_PORT: '7000' };
    assert.deepEqual(parseConfig([], env), { help: false, dataDir: '/env/data', port: 7000 });
  });

  it('prefers flags over environment variables', () => {
    const env = { SYNCBOX_DATA_DIR: '/env/data', SYNCBOX_PORT: '7000' };
    assert.deepEqual(parseConfig(['--data-dir', '/flag/data', '--port', '9000'], env), {
      help: false,
      dataDir: '/flag/data',
      port: 9000,
    });
  });

  it('mixes flag and environment sources', () => {
    assert.deepEqual(parseConfig(['--port', '9000'], { SYNCBOX_DATA_DIR: '/env/data' }), {
      help: false,
      dataDir: '/env/data',
      port: 9000,
    });
  });

  it('treats empty environment variables as unset', () => {
    assert.throws(() => parseConfig([], { SYNCBOX_DATA_DIR: '' }), ConfigError);
    assert.equal(parseConfig(['--data-dir', '/d'], { SYNCBOX_PORT: '' }).port, 8080);
  });

  it('requires a data directory', () => {
    assert.throws(() => parseConfig([], {}), { name: 'ConfigError', message: /data directory is required/ });
    assert.throws(() => parseConfig(['--port', '9000'], {}), ConfigError);
  });

  it('rejects a flag without a value', () => {
    assert.throws(() => parseConfig(['--data-dir'], {}), { message: /--data-dir requires a value/ });
    assert.throws(() => parseConfig(['--data-dir', '/d', '--port'], {}), { message: /--port requires a value/ });
  });

  for (const bad of ['abc', '-1', '0', '65536', '80.5', ' 80', '1e3', '0x50']) {
    it(`rejects invalid port ${JSON.stringify(bad)}`, () => {
      assert.throws(() => parseConfig(['--data-dir', '/d', '--port', bad], {}), { message: /invalid port/ });
      assert.throws(() => parseConfig(['--data-dir', '/d'], { SYNCBOX_PORT: bad }), { message: /invalid port/ });
    });
  }

  it('accepts boundary ports', () => {
    assert.equal(parseConfig(['--data-dir', '/d', '--port', '1'], {}).port, 1);
    assert.equal(parseConfig(['--data-dir', '/d', '--port', '65535'], {}).port, 65535);
  });

  it('rejects unknown arguments', () => {
    assert.throws(() => parseConfig(['--data-dir', '/d', '--verbose'], {}), { message: /unknown argument: --verbose/ });
    assert.throws(() => parseConfig(['positional'], {}), { message: /unknown argument/ });
  });

  it('recognises --help', () => {
    assert.deepEqual(parseConfig(['--help'], {}), { help: true });
    assert.deepEqual(parseConfig(['-h'], {}), { help: true });
  });
});
