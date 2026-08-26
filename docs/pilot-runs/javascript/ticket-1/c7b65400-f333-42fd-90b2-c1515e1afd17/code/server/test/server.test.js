'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createServer } = require('../src/server');

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

function get(port, path) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }));
    }).on('error', reject);
  });
}

test('GET /healthz returns 200', async (t) => {
  const server = createServer({ dataDir: '/tmp/unused' });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/healthz');
  assert.equal(res.status, 200);
});

test('unknown route returns 404', async (t) => {
  const server = createServer({ dataDir: '/tmp/unused' });
  const port = await listen(server);
  t.after(() => server.close());

  const res = await get(port, '/nope');
  assert.equal(res.status, 404);
});
