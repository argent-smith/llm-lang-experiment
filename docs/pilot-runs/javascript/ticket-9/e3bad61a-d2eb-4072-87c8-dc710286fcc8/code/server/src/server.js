'use strict';

const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { resolveBlobPath } = require('./safe-path');
const { writeFileAtomic, isTempFileName } = require('./atomic-write');

async function handlePutBlob(config, resolved, req, res) {
  // resolveBlobPath only validates the key's *structure* (traversal, absolute
  // paths, NUL bytes, lone surrogates). Some keys that pass that check still
  // can't be turned into a filesystem entry - the OS/filesystem itself may
  // reject the resulting name (odd byte sequences, length limits, transient
  // I/O errors on the target/temp file) - and PUT's contract only allows 201
  // or 400, never 500. So any failure to actually write the blob is treated
  // as the key being unusable, not a server error.
  let sha256, size;
  try {
    ({ sha256, size } = await writeFileAtomic(resolved.filePath, req));
  } catch (err) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end(`invalid key: could not store blob (${err.code || err.message})`);
    return;
  }

  res.writeHead(201, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ key: resolved.key, sha256, size }));
}

async function listBlobs(dataDir) {
  const results = [];

  async function walk(dir, segments) {
    const entries = await fsp.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (isTempFileName(entry.name)) continue;

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

// resolveBlobPath only validates the key's *structure* (traversal, absolute
// paths, NUL bytes, lone surrogates). Some structurally-valid keys still
// can't be turned into a filesystem entry - the OS/filesystem itself may
// reject the resulting name (odd byte sequences, length limits, transient
// I/O errors) - and GET/DELETE's contract only allows 404 or 400 alongside
// the success code, never 500. Such a key could never have been written to
// disk in the first place (PUT would fail the same way for it), so any
// failure to stat/read/unlink it - not just a clean ENOENT - is treated the
// same as the blob simply not being there.
async function handleGetBlob(config, resolved, req, res) {
  let body;
  try {
    body = await fsp.readFile(resolved.filePath);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
    return;
  }

  res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
  res.end(body);
}

async function handleDeleteBlob(config, resolved, req, res) {
  try {
    await fsp.unlink(resolved.filePath);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
    return;
  }

  res.writeHead(204);
  res.end();
}

function createServer(config) {
  return http.createServer((req, res) => {
    // A client disconnecting mid-request (e.g. aborting a PUT upload) emits
    // 'error' on req and/or res; without a listener that's an uncaught
    // exception that would crash the whole server process.
    req.on('error', () => {});
    res.on('error', () => {});

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
