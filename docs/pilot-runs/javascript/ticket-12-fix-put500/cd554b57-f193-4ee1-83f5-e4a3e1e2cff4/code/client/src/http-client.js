'use strict';

const http = require('http');
const https = require('https');

// Guards against a request hanging forever when the server accepts the TCP
// connection but never responds (e.g. dropped packets) - a plain
// ECONNREFUSED already rejects immediately without needing this.
const REQUEST_TIMEOUT_MS = 15000;

function encodeKey(key) {
  return key.split('/').map(encodeURIComponent).join('/');
}

function joinUrl(base, pathPart) {
  return `${base.replace(/\/+$/, '')}/${pathPart}`;
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

    const req = client.request(url, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
      res.on('error', reject);
    });

    req.on('error', (err) => reject(new Error(`request to ${url} failed: ${err.message}`)));
    req.setTimeout(REQUEST_TIMEOUT_MS, () => {
      req.destroy(new Error(`request to ${url} timed out after ${REQUEST_TIMEOUT_MS}ms`));
    });

    if (body === undefined) {
      req.end();
    } else if (typeof body.pipe === 'function') {
      body.on('error', reject);
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

module.exports = { listBlobs, putBlob, joinUrl, encodeKey };
