import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import { createServer } from '../src/server.js';

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
