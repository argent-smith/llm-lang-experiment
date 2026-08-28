'use strict';

const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { resolveBlobPath } = require('./safe-path');

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function handlePutBlob(config, resolved, req, res) {
  const body = await readBody(req);
  const sha256 = crypto.createHash('sha256').update(body).digest('hex');

  await fsp.mkdir(path.dirname(resolved.filePath), { recursive: true });
  await fsp.writeFile(resolved.filePath, body);

  res.writeHead(201, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ key: resolved.key, sha256, size: body.length }));
}

async function listBlobs(dataDir) {
  const results = [];

  async function walk(dir, segments) {
    const entries = await fsp.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const entryPath = path.join(dir, entry.name);
      const entrySegments = [...segments, entry.name];
      if (entry.isDirectory()) {
        await walk(entryPath, entrySegments);
      } else if (entry.isFile()) {
        const [stat, body] = await Promise.all([
          fsp.stat(entryPath),
          fsp.readFile(entryPath),
        ]);
        results.push({
          key: entrySegments.join('/'),
          size: stat.size,
          sha256: crypto.createHash('sha256').update(body).digest('hex'),
          modified_at: stat.mtime.toISOString(),
        });
      }
    }
  }

  await walk(dataDir, []);
  results.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return results;
}

async function handleListBlobs(config, req, res) {
  const blobs = await listBlobs(config.dataDir);
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(blobs));
}

async function handleGetBlob(config, resolved, req, res) {
  let body;
  try {
    body = await fsp.readFile(resolved.filePath);
  } catch (err) {
    if (err.code === 'ENOENT') {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('not found');
      return;
    }
    throw err;
  }

  res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
  res.end(body);
}

async function handleDeleteBlob(config, resolved, req, res) {
  try {
    await fsp.unlink(resolved.filePath);
  } catch (err) {
    if (err.code === 'ENOENT') {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('not found');
      return;
    }
    throw err;
  }

  res.writeHead(204);
  res.end();
}

function createServer(config) {
  return http.createServer((req, res) => {
    // Deliberately not using `new URL(req.url, ...).pathname`: the WHATWG URL
    // parser normalizes ".." (and even "%2e%2e") dot-segments away before we
    // ever see them, which would turn traversal attempts into a plain 404
    // instead of the required 400. Stripping only the query string keeps the
    // raw path intact for our own decode + resolve-based validation below.
    const queryIndex = req.url.indexOf('?');
    const pathname = queryIndex === -1 ? req.url : req.url.slice(0, queryIndex);

    if (req.method === 'GET' && pathname === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('ok');
      return;
    }

    if (req.method === 'GET' && pathname === '/blobs') {
      Promise.resolve(handleListBlobs(config, req, res)).catch((err) => {
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end(`internal error: ${err.message}`);
      });
      return;
    }

    const blobMatch = pathname.match(/^\/blobs\/(.+)$/);
    if (blobMatch) {
      const handler = req.method === 'PUT' ? handlePutBlob
        : req.method === 'GET' ? handleGetBlob
        : req.method === 'DELETE' ? handleDeleteBlob
        : null;

      if (handler) {
        const resolved = resolveBlobPath(config.dataDir, blobMatch[1]);
        if (!resolved) {
          res.writeHead(400, { 'Content-Type': 'text/plain' });
          res.end('invalid key');
          return;
        }

        Promise.resolve(handler(config, resolved, req, res)).catch((err) => {
          res.writeHead(500, { 'Content-Type': 'text/plain' });
          res.end(`internal error: ${err.message}`);
        });
        return;
      }
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
  });
}

module.exports = { createServer };
