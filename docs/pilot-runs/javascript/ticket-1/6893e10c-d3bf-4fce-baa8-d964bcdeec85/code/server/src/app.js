'use strict';

const http = require('http');
const { parseBlobKey, putBlob, listBlobs } = require('./blobStore');

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function rawPathOf(reqUrl) {
  const queryIndex = reqUrl.indexOf('?');
  return queryIndex === -1 ? reqUrl : reqUrl.slice(0, queryIndex);
}

function createApp(dataDir) {
  return http.createServer((req, res) => {
    Promise.resolve()
      .then(async () => {
        const rawPath = rawPathOf(req.url);

        if (req.method === 'GET' && rawPath === '/healthz') {
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end('ok');
          return;
        }

        if (req.method === 'GET' && rawPath === '/blobs') {
          const items = await listBlobs(dataDir);
          sendJson(res, 200, items);
          return;
        }

        if (req.method === 'PUT' && rawPath.startsWith('/blobs/')) {
          const rawKeyPath = rawPath.slice('/blobs/'.length);
          const key = parseBlobKey(rawKeyPath);
          if (key === null) {
            sendJson(res, 400, { error: 'invalid key' });
            return;
          }
          const body = await readBody(req);
          try {
            const result = await putBlob(dataDir, key, body);
            sendJson(res, 201, result);
          } catch (err) {
            console.error(`syncbox-server: put blob failed: ${err.message}`);
            sendJson(res, 400, { error: 'invalid key' });
          }
          return;
        }

        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('not found');
      })
      .catch((err) => {
        console.error(`syncbox-server: request failed: ${err.message}`);
        if (!res.headersSent) {
          sendJson(res, 400, { error: 'bad request' });
        } else {
          res.end();
        }
      });
  });
}

module.exports = { createApp };
