import http from 'node:http';
import { pipeline } from 'node:stream/promises';

import { BlobStore, InvalidKeyError, parseKey } from './blobs.js';

const BLOB_PREFIX = '/blobs/';

/**
 * Creates the Syncbox HTTP server (not yet listening).
 *
 * @param {{ dataDir: string }} options
 * @returns {http.Server}
 */
export function createServer({ dataDir }) {
  const ctx = { store: new BlobStore(dataDir) };
  const server = http.createServer((req, res) => {
    route(req, res, ctx).catch((err) => {
      // A client that hung up mid-request is not a server error.
      if (err?.code === 'ECONNRESET' || err?.code === 'ERR_STREAM_PREMATURE_CLOSE') {
        res.destroy();
        return;
      }
      console.error('unhandled error while serving %s %s:', req.method, req.url, err);
      if (!res.headersSent) {
        sendJson(res, 500, { error: 'internal server error' });
      } else {
        res.destroy();
      }
    });
  });
  return server;
}

async function route(req, res, ctx) {
  const path = pathOf(req.url);

  if (path === '/healthz') {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.setHeader('Allow', 'GET, HEAD');
      return sendJson(res, 405, { error: 'method not allowed' });
    }
    return sendJson(res, 200, { status: 'ok' });
  }

  if (path === '/blobs') {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.setHeader('Allow', 'GET, HEAD');
      return sendJson(res, 405, { error: 'method not allowed' });
    }
    return sendJson(res, 200, await ctx.store.list());
  }

  if (path.startsWith(BLOB_PREFIX) && req.method === 'PUT') {
    return putBlob(req, res, ctx, path.slice(BLOB_PREFIX.length));
  }

  if (path.startsWith(BLOB_PREFIX) && (req.method === 'GET' || req.method === 'HEAD')) {
    return getBlob(req, res, ctx, path.slice(BLOB_PREFIX.length));
  }

  return sendJson(res, 404, { error: 'not found' });
}

async function putBlob(req, res, ctx, rawKey) {
  try {
    const key = parseKey(rawKey);
    return sendJson(res, 201, await ctx.store.put(key, req));
  } catch (err) {
    if (err instanceof InvalidKeyError) {
      return sendJson(res, 400, { error: `invalid key: ${err.message}` });
    }
    throw err;
  }
}

async function getBlob(req, res, ctx, rawKey) {
  let blob;
  try {
    blob = await ctx.store.open(parseKey(rawKey));
  } catch (err) {
    if (err instanceof InvalidKeyError) {
      return sendJson(res, 400, { error: `invalid key: ${err.message}` });
    }
    throw err;
  }
  if (!blob) {
    return sendJson(res, 404, { error: 'blob not found' });
  }

  res.writeHead(200, {
    'Content-Type': 'application/octet-stream',
    'Content-Length': blob.size,
  });
  if (req.method === 'HEAD') {
    await blob.fh.close();
    res.end();
    return;
  }
  // The read stream closes the handle once it ends or is destroyed.
  await pipeline(blob.fh.createReadStream(), res);
}

// Raw path without the query string. Deliberately not using `new URL()`:
// it would normalise away things like `..` segments that later handlers
// must see verbatim in order to reject them.
function pathOf(rawUrl = '/') {
  const q = rawUrl.indexOf('?');
  return q === -1 ? rawUrl : rawUrl.slice(0, q);
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(res.req.method === 'HEAD' ? undefined : payload);
}
