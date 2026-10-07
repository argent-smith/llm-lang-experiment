import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, beforeEach, describe, it } from 'node:test';

import { createServer } from '../src/server.js';

// Sends a request with the path exactly as given: fetch() (and http.request
// with a URL string) would normalise `..` segments and escapes away first.
function rawRequest(baseUrl, method, rawPath, body) {
  const { hostname, port } = new URL(baseUrl);
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname, port, method, path: rawPath }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const body = Buffer.concat(chunks);
        const text = body.toString();
        const json = /json/.test(res.headers['content-type'] ?? '') && text ? JSON.parse(text) : undefined;
        resolve({ status: res.statusCode, headers: res.headers, body, text, json });
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}

const sha256 = (data) => createHash('sha256').update(data).digest('hex');

// Percent-encodes every byte, so arbitrary byte sequences can be sent as a key.
const encodeBytes = (bytes) => [...bytes].map((b) => `%${b.toString(16).padStart(2, '0')}`).join('');

// Small deterministic PRNG so the fuzz cases are reproducible.
function prng(seed) {
  let x = seed >>> 0;
  return () => {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    return (x >>> 0) / 2 ** 32;
  };
}

describe('HTTP server', () => {
  let server;
  let baseUrl;

  before(async () => {
    server = createServer({ dataDir: '/nonexistent-unused-by-healthz' });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });

  it('GET /healthz returns 200', async () => {
    const res = await fetch(`${baseUrl}/healthz`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: 'ok' });
  });

  it('GET /healthz ignores the query string', async () => {
    const res = await fetch(`${baseUrl}/healthz?probe=1`);
    assert.equal(res.status, 200);
    await res.body?.cancel();
  });

  it('HEAD /healthz returns 200 without a body', async () => {
    const res = await fetch(`${baseUrl}/healthz`, { method: 'HEAD' });
    assert.equal(res.status, 200);
    assert.equal(await res.text(), '');
  });

  it('rejects other methods on /healthz with 405', async () => {
    const res = await fetch(`${baseUrl}/healthz`, { method: 'POST' });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'GET, HEAD');
    await res.body?.cancel();
  });

  it('returns 404 for unknown paths', async () => {
    const res = await fetch(`${baseUrl}/no-such-endpoint`);
    assert.equal(res.status, 404);
    await res.body?.cancel();
  });
});

describe('blob endpoints', () => {
  let server;
  let baseUrl;
  let dataDir;
  let tmp;

  before(async () => {
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'syncbox-blobs-'));
  });

  beforeEach(async () => {
    if (server) {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
    dataDir = await fs.mkdtemp(path.join(tmp, 'data-'));
    server = createServer({ dataDir });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(tmp, { recursive: true, force: true });
  });

  const put = (rawKey, body) => rawRequest(baseUrl, 'PUT', `/blobs/${rawKey}`, body);
  const get = (rawKey, method = 'GET') => rawRequest(baseUrl, method, `/blobs/${rawKey}`);
  const list = () => rawRequest(baseUrl, 'GET', '/blobs');

  describe('GET /blobs', () => {
    it('returns 200 and an empty array on a fresh data directory', async () => {
      const res = await list();
      assert.equal(res.status, 200);
      assert.match(res.headers['content-type'], /^application\/json/);
      assert.deepEqual(res.json, []);
    });

    it('ignores the query string', async () => {
      const res = await rawRequest(baseUrl, 'GET', '/blobs?limit=x');
      assert.equal(res.status, 200);
      assert.deepEqual(res.json, []);
    });

    it('lists stored blobs with key, size, sha256 and modified_at, sorted by key', async () => {
      const startedAt = Date.now();
      await put('docs/readme.txt', 'hello');
      await put('a', '');
      await put('docs/sub/deep.bin', Buffer.from([0, 1, 2, 255]));

      const res = await list();
      assert.equal(res.status, 200);
      assert.deepEqual(
        res.json.map(({ key, size, sha256 }) => ({ key, size, sha256 })),
        [
          { key: 'a', size: 0, sha256: sha256('') },
          { key: 'docs/readme.txt', size: 5, sha256: sha256('hello') },
          { key: 'docs/sub/deep.bin', size: 4, sha256: sha256(Buffer.from([0, 1, 2, 255])) },
        ],
      );
      for (const blob of res.json) {
        assert.match(blob.modified_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$/);
        assert.ok(Date.parse(blob.modified_at) >= startedAt - 2000);
      }
    });

    it('does not list uploads that failed', async () => {
      assert.equal((await put('x', '1')).status, 201);
      assert.equal((await put('x/y', '2')).status, 400);
      assert.deepEqual((await list()).json.map((b) => b.key), ['x']);
    });

    it('HEAD /blobs returns 200 without a body', async () => {
      const res = await rawRequest(baseUrl, 'HEAD', '/blobs');
      assert.equal(res.status, 200);
      assert.equal(res.text, '');
    });

    it('rejects other methods on /blobs with 405', async () => {
      const res = await rawRequest(baseUrl, 'POST', '/blobs');
      assert.equal(res.status, 405);
      assert.equal(res.headers.allow, 'GET, HEAD');
    });
  });

  describe('PUT /blobs/{key}', () => {
    it('stores a blob with an empty body under key "0" and returns 201', async () => {
      const res = await put('0');
      assert.equal(res.status, 201);
      assert.deepEqual(res.json, { key: '0', sha256: sha256(''), size: 0 });
    });

    it('stores the body and returns key, sha256 and size', async () => {
      const body = Buffer.from('some bytes \u00e9\n');
      const res = await put('docs/readme.txt', body);
      assert.equal(res.status, 201);
      assert.deepEqual(res.json, { key: 'docs/readme.txt', sha256: sha256(body), size: body.length });
      assert.deepEqual(await fs.readFile(path.join(dataDir, 'blobs', 'docs', 'readme.txt')), body);
    });

    it('overwrites an existing blob', async () => {
      await put('k', 'old');
      const res = await put('k', 'new contents');
      assert.equal(res.status, 201);
      assert.equal(res.json.sha256, sha256('new contents'));
      assert.deepEqual((await list()).json.map((b) => [b.key, b.size]), [['k', 12]]);
    });

    it('decodes percent-encoded keys, including %2F as a separator', async () => {
      const res = await put('dir%2Fna%20me%E2%9C%93');
      assert.equal(res.status, 201);
      assert.equal(res.json.key, 'dir/na me\u2713');
      assert.deepEqual((await list()).json.map((b) => b.key), ['dir/na me\u2713']);
    });

    it('ignores the query string', async () => {
      const res = await put('q?x=1', 'data');
      assert.equal(res.status, 201);
      assert.equal(res.json.key, 'q');
    });

    const invalidKeys = {
      'empty key': '',
      'parent segment': '../escape',
      'parent segment in the middle': 'a/../../escape',
      'trailing parent segment': 'a/..',
      'percent-encoded parent segment': '%2e%2E/escape',
      'parent segment via encoded slash': '..%2Fescape',
      'absolute path': '/etc/passwd',
      'encoded absolute path': '%2Fetc%2Fpasswd',
      'dot segment': './a',
      'empty segment': 'a//b',
      'trailing slash': 'a/',
      'malformed percent-encoding': '%zz',
      'truncated percent-encoding': 'a%',
      'invalid UTF-8': '%ff%fe',
      'encoded lone surrogate': '%ED%A0%80',
      'NUL byte': 'a%00b',
      'overlong segment': 'x'.repeat(256),
      'overlong multibyte segment': '%C3%A9'.repeat(128),
      'overlong total path': Array(40).fill('y'.repeat(200)).join('/'),
    };
    for (const [name, rawKey] of Object.entries(invalidKeys)) {
      it(`rejects ${name} with 400`, async () => {
        const res = await put(rawKey, 'payload');
        assert.equal(res.status, 400, `PUT /blobs/${rawKey}`);
        assert.match(res.json.error, /invalid key/);
      });
    }

    it('accepts a segment of exactly 255 bytes', async () => {
      assert.equal((await put('z'.repeat(255))).status, 201);
    });

    it('returns 400 when a key needs a directory where a blob already is', async () => {
      assert.equal((await put('file', 'x')).status, 201);
      assert.equal((await put('file/child', 'y')).status, 400);
    });

    it('returns 400 when a key names a directory holding other blobs', async () => {
      assert.equal((await put('dir/child', 'x')).status, 201);
      assert.equal((await put('dir', 'y')).status, 400);
    });

    it('never writes outside the blob root', async () => {
      for (const rawKey of Object.values(invalidKeys)) await put(rawKey, 'escaped');
      assert.deepEqual((await list()).json, []);
      for (const name of await fs.readdir(dataDir)) assert.ok(['blobs', 'tmp'].includes(name), name);
      assert.deepEqual(await fs.readdir(path.join(dataDir, 'tmp')).catch(() => []), []);
      assert.deepEqual((await fs.readdir(tmp)).filter((n) => !n.startsWith('data-')), []);
    });

    it('answers only 201 or 400 for arbitrary byte sequences as keys', async () => {
      const random = prng(0x5eed);
      const alphabet = ['.', '/', '%', 'a', '0', '\\', '~', ':', '%2F', '%2e', '%00', '%ff', '%C3', '%A9', '..'];
      for (let i = 0; i < 300; i++) {
        const len = Math.floor(random() * 12);
        const rawKey =
          i % 2 === 0
            ? encodeBytes(Array.from({ length: len }, () => Math.floor(random() * 256)))
            : Array.from({ length: len }, () => alphabet[Math.floor(random() * alphabet.length)]).join('');
        const res = await put(rawKey, 'x');
        assert.ok([201, 400].includes(res.status), `PUT /blobs/${rawKey} -> ${res.status}`);
      }
      const res = await list();
      assert.equal(res.status, 200);
      for (const blob of res.json) {
        assert.ok(!blob.key.split('/').some((s) => s === '' || s === '.' || s === '..'), blob.key);
      }
    });
  });

  describe('GET /blobs/{key}', () => {
    it('returns the stored bytes unchanged', async () => {
      const body = Buffer.from(Array.from({ length: 1024 }, (_, i) => i % 256));
      assert.equal((await put('bin', body)).status, 201);
      const res = await get('bin');
      assert.equal(res.status, 200);
      assert.equal(res.headers['content-type'], 'application/octet-stream');
      assert.equal(res.headers['content-length'], String(body.length));
      assert.deepEqual(res.body, body);
    });

    it('round-trips a blob under a nested key', async () => {
      const body = Buffer.from('hello from a nested directory\n');
      assert.equal((await put('docs/sub/deeper/readme.txt', body)).status, 201);
      const res = await get('docs/sub/deeper/readme.txt');
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, body);
    });

    it('round-trips a blob larger than one read chunk', async () => {
      const random = prng(42);
      const body = Buffer.from(Array.from({ length: 3 * 1024 * 1024 + 7 }, () => Math.floor(random() * 256)));
      const putRes = await put('large.bin', body);
      assert.equal(putRes.status, 201);
      assert.deepEqual(putRes.json, { key: 'large.bin', sha256: sha256(body), size: body.length });
      const res = await get('large.bin');
      assert.equal(res.status, 200);
      assert.equal(res.body.length, body.length);
      assert.equal(sha256(res.body), sha256(body));
    });

    it('returns an empty body for an empty blob', async () => {
      assert.equal((await put('empty', '')).status, 201);
      const res = await get('empty');
      assert.equal(res.status, 200);
      assert.equal(res.headers['content-length'], '0');
      assert.equal(res.body.length, 0);
    });

    it('returns the latest contents after an overwrite', async () => {
      await put('k', 'old contents');
      await put('k', 'new');
      const res = await get('k');
      assert.equal(res.status, 200);
      assert.equal(res.text, 'new');
    });

    it('finds a blob by its percent-encoded key', async () => {
      assert.equal((await put('dir%2Fna%20me%E2%9C%93', 'encoded')).status, 201);
      assert.equal((await get('dir/na%20me%E2%9C%93')).text, 'encoded');
      assert.equal((await get('dir%2Fna%20me%E2%9C%93')).text, 'encoded');
    });

    it('ignores the query string', async () => {
      await put('q', 'data');
      const res = await get('q?x=1');
      assert.equal(res.status, 200);
      assert.equal(res.text, 'data');
    });

    it('returns 404 for a key that was never stored', async () => {
      const res = await get('missing.txt');
      assert.equal(res.status, 404);
      assert.match(res.json.error, /not found/);
    });

    it('returns 404 for a missing key in a missing directory', async () => {
      assert.equal((await get('no/such/dir/file')).status, 404);
    });

    it('returns 404 for a key that is a directory of other blobs', async () => {
      await put('dir/child', 'x');
      assert.equal((await get('dir')).status, 404);
    });

    it('returns 404 for a key below an existing blob', async () => {
      await put('file', 'x');
      assert.equal((await get('file/child')).status, 404);
    });

    it('HEAD returns the headers of GET without a body', async () => {
      await put('h', 'twelve bytes');
      const res = await get('h', 'HEAD');
      assert.equal(res.status, 200);
      assert.equal(res.headers['content-length'], '12');
      assert.equal(res.body.length, 0);
      assert.equal((await get('missing', 'HEAD')).status, 404);
    });

    it('answers 400 or 404, never 5xx, for keys that cannot name a blob', async () => {
      for (const rawKey of ['', '%zz', '%ff%fe', 'a%00b', 'a//b', 'x'.repeat(256), Array(40).fill('y'.repeat(200)).join('/')]) {
        const res = await get(rawKey);
        assert.ok([400, 404].includes(res.status), `GET /blobs/${rawKey} -> ${res.status}`);
      }
    });
  });
});
