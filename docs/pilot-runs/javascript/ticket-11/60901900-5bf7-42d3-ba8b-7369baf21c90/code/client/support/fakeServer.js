'use strict';

const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');

function sha256Of(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

// A minimal in-memory stand-in for the Syncbox server's /blobs surface,
// used to test the client's push/pull/sync logic in isolation without
// depending on the server package (the client's Docker build context
// doesn't include it, so client tests must be self-contained).
//
// initialBlobs values may be a plain Buffer (modified_at defaults to "now")
// or a { buffer, modifiedAt } object -- sync's conflict rule needs tests to
// pin down an exact modified_at, which a bare Buffer can't express.
//
// options.failKeys lists keys for which GET and PUT both return 500,
// simulating a server-side failure on one specific blob while the rest of
// the surface keeps working -- used to test client partial-failure handling
// without needing a real flaky server.
function createFakeServer(initialBlobs = {}, options = {}) {
  const failKeys = new Set(options.failKeys || []);
  const blobs = new Map(); // key -> { buffer, sha256, modifiedAt }
  for (const [key, value] of Object.entries(initialBlobs)) {
    const buffer = Buffer.isBuffer(value) ? value : value.buffer;
    const modifiedAt = Buffer.isBuffer(value) ? new Date().toISOString() : value.modifiedAt;
    blobs.set(key, { buffer, sha256: sha256Of(buffer), modifiedAt });
  }
  const puts = [];

  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      const url = req.url;

      if (req.method === 'GET' && url === '/blobs') {
        const items = Array.from(blobs.entries()).map(([key, blob]) => ({
          key,
          size: blob.buffer.length,
          sha256: blob.sha256,
          modified_at: blob.modifiedAt,
        }));
        const payload = JSON.stringify(items);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(payload);
        return;
      }

      if (req.method === 'GET' && url.startsWith('/blobs/')) {
        const key = url
          .slice('/blobs/'.length)
          .split('/')
          .map(decodeURIComponent)
          .join('/');
        if (failKeys.has(key)) {
          res.writeHead(500, { 'Content-Type': 'text/plain' });
          res.end('simulated server error');
          return;
        }
        const blob = blobs.get(key);
        if (!blob) {
          res.writeHead(404, { 'Content-Type': 'text/plain' });
          res.end('not found');
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
        res.end(blob.buffer);
        return;
      }

      if (req.method === 'PUT' && url.startsWith('/blobs/')) {
        const key = url
          .slice('/blobs/'.length)
          .split('/')
          .map(decodeURIComponent)
          .join('/');
        if (failKeys.has(key)) {
          res.writeHead(500, { 'Content-Type': 'text/plain' });
          res.end('simulated server error');
          return;
        }
        const sha256 = sha256Of(body);
        const modifiedAt = new Date().toISOString();
        blobs.set(key, { buffer: body, sha256, modifiedAt });
        puts.push({ key, body });
        const payload = JSON.stringify({ key, sha256, size: body.length });
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(payload);
        return;
      }

      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('not found');
    });
  });

  return {
    server,
    puts,
    blobs,
    async listen() {
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      const { port } = server.address();
      return `http://127.0.0.1:${port}`;
    },
    async close() {
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

// A raw TCP listener that accepts connections but never writes a byte back.
// Stands in for a server process that is up (the TCP handshake succeeds,
// unlike a closed port) but wedged and never answering -- used to exercise
// the client's request timeout, as opposed to its "connection refused"
// handling which a closed port already covers.
function createHangingServer() {
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
  });
  return {
    async listen() {
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      const { port } = server.address();
      return `http://127.0.0.1:${port}`;
    },
    async close() {
      // net.Server#close() only stops accepting new connections; it waits
      // for already-open ones to end on their own before its callback
      // fires. The whole point of this server is to never respond, so the
      // client side may or may not have torn down its end of the socket by
      // the time a test is done with it -- destroy them explicitly instead
      // of waiting.
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

module.exports = { createFakeServer, sha256Of, createHangingServer };
