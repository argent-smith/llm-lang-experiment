import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { ConfigError, parseClientArgs } from '../src/client-config.js';

const SERVER = 'http://127.0.0.1:8080';

describe('parseClientArgs', () => {
  it('parses <command> <dir> --server <url>', () => {
    const config = parseClientArgs(['push', 'some/dir', '--server', SERVER]);
    assert.equal(config.help, false);
    assert.equal(config.command, 'push');
    assert.equal(config.dir, 'some/dir');
    assert.equal(config.server.href, `${SERVER}/`);
  });

  it('accepts every command of the CLI contract', () => {
    for (const command of ['push', 'pull', 'status', 'sync']) {
      assert.equal(parseClientArgs([command, 'd', '--server', SERVER]).command, command);
    }
  });

  it('accepts --server=<url> and options before the command', () => {
    assert.equal(parseClientArgs([`--server=${SERVER}`, 'push', 'd']).server.href, `${SERVER}/`);
    assert.equal(parseClientArgs(['--server', SERVER, 'push', 'd']).dir, 'd');
  });

  it('falls back to SYNCBOX_SERVER', () => {
    const config = parseClientArgs(['push', 'd'], { SYNCBOX_SERVER: 'http://example.com:9000' });
    assert.equal(config.server.href, 'http://example.com:9000/');
  });

  it('prefers --server over SYNCBOX_SERVER', () => {
    const config = parseClientArgs(['push', 'd', '--server', SERVER], { SYNCBOX_SERVER: 'http://example.com:9000' });
    assert.equal(config.server.href, `${SERVER}/`);
  });

  it('requires a server URL', () => {
    assert.throws(() => parseClientArgs(['push', 'd']), { name: 'ConfigError', message: /server URL is required/ });
    assert.throws(() => parseClientArgs(['push', 'd'], { SYNCBOX_SERVER: '' }), ConfigError);
    assert.throws(() => parseClientArgs(['push', 'd', '--server']), { message: /--server requires a value/ });
  });

  it('rejects server URLs that are not http(s) base URLs', () => {
    for (const bad of ['127.0.0.1:8080', 'not a url', 'ftp://example.com', 'http://h/?q=1', 'http://h/#x']) {
      assert.throws(() => parseClientArgs(['push', 'd', '--server', bad]), { message: /invalid server URL/ }, bad);
    }
    assert.equal(parseClientArgs(['push', 'd', '--server', 'https://h/prefix/']).server.href, 'https://h/prefix/');
  });

  it('requires a known command and a directory', () => {
    assert.throws(() => parseClientArgs(['--server', SERVER]), { message: /a command is required/ });
    assert.throws(() => parseClientArgs(['upload', 'd', '--server', SERVER]), { message: /unknown command: upload/ });
    assert.throws(() => parseClientArgs(['push', '--server', SERVER]), { message: /push requires a directory/ });
    assert.throws(() => parseClientArgs(['push', '', '--server', SERVER]), { message: /push requires a directory/ });
  });

  it('rejects unknown options and extra arguments', () => {
    assert.throws(() => parseClientArgs(['push', 'd', '--server', SERVER, '--force']), { message: /unknown option: --force/ });
    assert.throws(() => parseClientArgs(['push', 'd', 'e', '--server', SERVER]), { message: /unexpected argument: e/ });
  });

  it('takes everything after -- as positional', () => {
    assert.equal(parseClientArgs(['--server', SERVER, 'push', '--', '-dir']).dir, '-dir');
  });

  it('recognises --help anywhere', () => {
    assert.deepEqual(parseClientArgs(['--help']), { help: true });
    assert.deepEqual(parseClientArgs(['push', '-h']), { help: true });
  });
});
