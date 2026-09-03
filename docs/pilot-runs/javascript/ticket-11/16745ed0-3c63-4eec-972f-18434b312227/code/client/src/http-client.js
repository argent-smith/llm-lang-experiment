'use strict';

const http = require('http');
const https = require('https');

// Guards against a request hanging forever when the server accepts the TCP
// connection but never responds (e.g. dropped packets) - a plain
// ECONNREFUSED already rejects immediately without needing this. Overridable
// only through this internal env var so the test suite can exercise the
// timeout path without waiting out the real production value; it is not a
// supported user-facing setting (no CLI flag or documented env var for it).
const REQUEST_TIMEOUT_MS = Number(process.env.SYNCBOX_TEST_ONLY_REQUEST_TIMEOUT_MS) || 15000;

function encodeKey(key) {
  return key.split('/').map(encodeURIComponent).join('/');
}

function joinUrl(base, pathPart) {
  return `${base.replace(/\/+$/, '')}/${pathPart}`;
}

// Turns a raw Node network error into a short, human-readable cause phrase
// so stderr tells the user *why* the server was unreachable, not just that
// it was.
function describeCause(err) {
  switch (err.code) {
    case 'ECONNREFUSED':
      return 'connection refused';
    case 'ENOTFOUND':
    case 'EAI_AGAIN':
      return 'server host name could not be resolved';
    case 'ECONNRESET':
      return 'connection reset';
    case 'EHOSTUNREACH':
    case 'ENETUNREACH':
      return 'server host unreachable';
    default:
      return err.message;
  }
}

function request(fullUrl, method, { headers, body } = {}) {
  return new Promise((resolve, reject) => {
    let url;
    try {
      url = new URL(fullUrl);
    } catch {
      reject(new Error(`invalid server URL: ${fullUrl}`));
      return;
    }
    const client = url.protocol === 'https:' ? https : http;

    let settled = false;
    let timedOut = false;

    const req = client.request(url, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        if (settled) return;
        settled = true;
        resolve({ status: res.statusCode, body: Buffer.concat(chunks) });
      });
      res.on('error', (err) => {
        if (settled) return;
        settled = true;
        reject(new Error(`reading response from ${url} failed: ${err.message}`));
      });
    });

    req.on('error', (err) => {
      if (settled) return;
      settled = true;
      if (timedOut) {
        reject(new Error(`request to ${url} timed out after ${REQUEST_TIMEOUT_MS}ms waiting for the server`));
      } else {
        reject(new Error(`could not reach ${url}: ${describeCause(err)} (${err.message})`));
      }
    });

    req.setTimeout(REQUEST_TIMEOUT_MS, () => {
      timedOut = true;
      req.destroy(new Error('timeout'));
    });

    if (body === undefined) {
      req.end();
    } else if (typeof body.pipe === 'function') {
      body.on('error', (err) => {
        if (settled) return;
        settled = true;
        reject(err);
        req.destroy();
      });
      body.pipe(req);
    } else {
      req.end(body);
    }
  });
}

async function listBlobs(serverUrl) {
  const res = await request(joinUrl(serverUrl, 'blobs'), 'GET');
  if (res.status !== 200) {
    throw new Error(`GET /blobs failed with status ${res.status}`);
  }
  return JSON.parse(res.body.toString('utf8'));
}

async function putBlob(serverUrl, key, body, { contentLength } = {}) {
  const headers = { 'Content-Type': 'application/octet-stream' };
  if (contentLength !== undefined) headers['Content-Length'] = contentLength;

  const res = await request(joinUrl(serverUrl, `blobs/${encodeKey(key)}`), 'PUT', { headers, body });
  if (res.status !== 201) {
    throw new Error(`PUT /blobs/${key} failed with status ${res.status}: ${res.body.toString('utf8')}`);
  }
  return JSON.parse(res.body.toString('utf8'));
}

async function getBlob(serverUrl, key) {
  const res = await request(joinUrl(serverUrl, `blobs/${encodeKey(key)}`), 'GET');
  if (res.status !== 200) {
    throw new Error(`GET /blobs/${key} failed with status ${res.status}: ${res.body.toString('utf8')}`);
  }
  return res.body;
}

module.exports = { listBlobs, putBlob, getBlob, joinUrl, encodeKey };
