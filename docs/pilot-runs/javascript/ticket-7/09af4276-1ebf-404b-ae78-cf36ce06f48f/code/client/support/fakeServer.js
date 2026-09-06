'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

// A minimal in-memory stand-in for the Syncbox server's /blobs surface,
// used to test the client's push logic in isolation without depending on
// the server package (the client's Docker build context doesn't include
// it, so client tests must be self-contained).
function createFakeServer(initialBlobs = {}) {
  const blobs = new Map(); // key -> { buffer, sha256 }
  for (const [key, buffer] of Object.entries(initialBlobs)) {
    blobs.set(key, { buffer, sha256: sha256Of(buffer) });
  }
  const puts = [];

  function sha256Of(buffer) {
    return crypto.createHash('sha256').update(buffer).digest('hex');
  }

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
          modified_at: new Date(0).toISOString(),
        }));
        const payload = JSON.stringify(items);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(payload);
        return;
      }

      if (req.method === 'PUT' && url.startsWith('/blobs/')) {
        const key = url
          .slice('/blobs/'.length)
          .split('/')
          .map(decodeURIComponent)
          .join('/');
        const sha256 = sha256Of(body);
        blobs.set(key, { buffer: body, sha256 });
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

module.exports = { createFakeServer };
