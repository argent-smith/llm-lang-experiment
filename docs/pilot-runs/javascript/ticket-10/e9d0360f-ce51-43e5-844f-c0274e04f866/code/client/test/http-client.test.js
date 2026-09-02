'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { listBlobs, putBlob, getBlob, joinUrl, encodeKey } = require('../src/http-client');

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

test('joinUrl joins a base without a trailing slash', () => {
  assert.equal(joinUrl('http://localhost:8080', 'blobs'), 'http://localhost:8080/blobs');
});

test('joinUrl joins a base with a trailing slash', () => {
  assert.equal(joinUrl('http://localhost:8080/', 'blobs'), 'http://localhost:8080/blobs');
});

test('encodeKey percent-encodes each path segment but keeps slashes literal', () => {
  assert.equal(encodeKey('docs/my file.txt'), 'docs/my%20file.txt');
});

test('listBlobs parses the JSON array returned by the server', async (t) => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify([{ key: 'a.txt', size: 1, sha256: 'x', modified_at: 'now' }]));
  });
  const port = await listen(server);
  t.after(() => server.close());

  const blobs = await listBlobs(`http://127.0.0.1:${port}`);
  assert.deepEqual(blobs, [{ key: 'a.txt', size: 1, sha256: 'x', modified_at: 'now' }]);
});

test('listBlobs throws when the server responds with a non-200 status', async (t) => {
  const server = http.createServer((req, res) => {
    res.writeHead(500);
    res.end('boom');
  });
  const port = await listen(server);
  t.after(() => server.close());

  await assert.rejects(() => listBlobs(`http://127.0.0.1:${port}`), /status 500/);
});

test('listBlobs rejects when the server is unreachable', async () => {
  await assert.rejects(() => listBlobs('http://127.0.0.1:1'));
});

test('putBlob sends the request body and returns the parsed response', async (t) => {
  let received = Buffer.alloc(0);
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      received = Buffer.concat(chunks);
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ key: 'a.txt', sha256: 'x', size: received.length }));
    });
  });
  const port = await listen(server);
  t.after(() => server.close());

  const result = await putBlob(`http://127.0.0.1:${port}`, 'a.txt', Buffer.from('hello'));
  assert.equal(received.toString(), 'hello');
  assert.deepEqual(result, { key: 'a.txt', sha256: 'x', size: 5 });
});

test('putBlob accepts a readable stream as the body', async (t) => {
  const { Readable } = require('node:stream');
  let received = Buffer.alloc(0);
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      received = Buffer.concat(chunks);
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ key: 'a.txt', sha256: 'x', size: received.length }));
    });
  });
  const port = await listen(server);
  t.after(() => server.close());

  await putBlob(`http://127.0.0.1:${port}`, 'a.txt', Readable.from([Buffer.from('streamed')]));
  assert.equal(received.toString(), 'streamed');
});

test('putBlob throws with the response body when status is not 201', async (t) => {
  const server = http.createServer((req, res) => {
    req.on('data', () => {});
    req.on('end', () => {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('invalid key');
    });
  });
  const port = await listen(server);
  t.after(() => server.close());

  await assert.rejects(
    () => putBlob(`http://127.0.0.1:${port}`, 'a.txt', Buffer.from('hello')),
    /status 400/
  );
});

test('putBlob percent-encodes nested keys in the request path', async (t) => {
  let requestedPath;
  const server = http.createServer((req, res) => {
    requestedPath = req.url;
    req.on('data', () => {});
    req.on('end', () => {
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ key: 'docs/my file.txt', sha256: 'x', size: 0 }));
    });
  });
  const port = await listen(server);
  t.after(() => server.close());

  await putBlob(`http://127.0.0.1:${port}`, 'docs/my file.txt', Buffer.from(''));
  assert.equal(requestedPath, '/blobs/docs/my%20file.txt');
});

test('getBlob returns the raw response body', async (t) => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
    res.end(Buffer.from('hello'));
  });
  const port = await listen(server);
  t.after(() => server.close());

  const body = await getBlob(`http://127.0.0.1:${port}`, 'a.txt');
  assert.equal(body.toString(), 'hello');
});

test('getBlob percent-encodes nested keys in the request path', async (t) => {
  let requestedPath;
  const server = http.createServer((req, res) => {
    requestedPath = req.url;
    res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
    res.end(Buffer.from('deep'));
  });
  const port = await listen(server);
  t.after(() => server.close());

  await getBlob(`http://127.0.0.1:${port}`, 'docs/my file.txt');
  assert.equal(requestedPath, '/blobs/docs/my%20file.txt');
});

test('getBlob throws when the server responds with a non-200 status', async (t) => {
  const server = http.createServer((req, res) => {
    res.writeHead(404);
    res.end('not found');
  });
  const port = await listen(server);
  t.after(() => server.close());

  await assert.rejects(() => getBlob(`http://127.0.0.1:${port}`, 'missing.txt'), /status 404/);
});

test('getBlob rejects when the server is unreachable', async () => {
  await assert.rejects(() => getBlob('http://127.0.0.1:1', 'a.txt'));
});
