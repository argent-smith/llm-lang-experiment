'use strict';

const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function handlePutBlob(config, key, req, res) {
  const body = await readBody(req);
  const sha256 = crypto.createHash('sha256').update(body).digest('hex');
  const filePath = path.join(config.dataDir, key);

  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.writeFile(filePath, body);

  res.writeHead(201, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ key, sha256, size: body.length }));
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

async function handleGetBlob(config, key, req, res) {
  const filePath = path.join(config.dataDir, key);

  let body;
  try {
    body = await fsp.readFile(filePath);
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

async function handleDeleteBlob(config, key, req, res) {
  const filePath = path.join(config.dataDir, key);

  try {
    await fsp.unlink(filePath);
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
    const pathname = new URL(req.url, 'http://localhost').pathname;

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
      const key = decodeURIComponent(blobMatch[1]);

      const handler = req.method === 'PUT' ? handlePutBlob
        : req.method === 'GET' ? handleGetBlob
        : req.method === 'DELETE' ? handleDeleteBlob
        : null;

      if (handler) {
        Promise.resolve(handler(config, key, req, res)).catch((err) => {
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
