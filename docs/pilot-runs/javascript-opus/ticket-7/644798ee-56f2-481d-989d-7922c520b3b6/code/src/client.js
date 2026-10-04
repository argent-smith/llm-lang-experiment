// HTTP client for the Syncbox server API (see syncbox-openapi.yaml).
//
// Built on node:http rather than fetch(): fetch refuses a list of "bad
// ports" (6000, 10080, ...) that a Syncbox server may well listen on.

import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';

export class RequestError extends Error {
  constructor(message) {
    super(message);
    this.name = 'RequestError';
  }
}

export class SyncboxClient {
  /** @param {URL} server  base URL; may include a path prefix */
  constructor(server) {
    this.server = server;
    // Without the trailing slash, so that appending "/blobs" works for both
    // http://host:8080 and http://host/prefix/.
    this.base = server.origin + server.pathname.replace(/\/+$/, '');
  }

  /**
   * Lists blobs stored on the server.
   *
   * @returns {Promise<Array<{ key: string, sha256: string, size: number, modified_at: string }>>}
   * @throws {RequestError}
   */
  async list() {
    const res = await this.#request('GET', `${this.base}/blobs`);
    if (res.status !== 200) {
      throw new RequestError(`GET /blobs: ${describeFailure(res)}`);
    }
    let blobs;
    try {
      blobs = JSON.parse(res.body.toString('utf8'));
    } catch (err) {
      throw new RequestError(`GET /blobs: response is not valid JSON: ${err.message}`);
    }
    if (!Array.isArray(blobs) || !blobs.every((b) => typeof b?.key === 'string' && typeof b?.sha256 === 'string')) {
      throw new RequestError('GET /blobs: response is not a list of blobs');
    }
    return blobs;
  }

  /**
   * Uploads the contents of a local file as the blob `key`, replacing any
   * blob already stored under it.
   *
   * @param {string} key
   * @param {string} file  path of the local file
   * @returns {Promise<{ key: string, sha256: string, size: number }>}
   * @throws {RequestError} if the server cannot be reached or rejects the upload
   * @throws {Error} if the file cannot be read
   */
  async put(key, file) {
    // Sent chunked rather than with a Content-Length taken from stat(): a
    // file that shrinks while being read would leave the server waiting for
    // bytes that never come.
    const res = await this.#request('PUT', `${this.base}/blobs/${encodeKey(key)}`, {
      headers: { 'Content-Type': 'application/octet-stream' },
      body: fs.createReadStream(file),
    });
    if (res.status !== 201) {
      throw new RequestError(`PUT ${key}: ${describeFailure(res)}`);
    }
    try {
      return JSON.parse(res.body.toString('utf8'));
    } catch (err) {
      throw new RequestError(`PUT ${key}: response is not valid JSON: ${err.message}`);
    }
  }

  /**
   * @param {string} method
   * @param {string} url
   * @param {{ headers?: Record<string, string>, body?: import('node:stream').Readable }} [options]
   * @returns {Promise<{ status: number, statusText: string, body: Buffer }>}
   */
  #request(method, url, { headers = {}, body } = {}) {
    return new Promise((resolve, reject) => {
      const transport = url.startsWith('https:') ? https : http;
      const req = transport.request(url, { method, headers }, (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          // The server may answer (e.g. 400) without reading the whole body.
          body?.destroy();
          resolve({ status: res.statusCode, statusText: res.statusMessage, body: Buffer.concat(chunks) });
        });
        res.on('error', (err) => reject(this.#networkError(err)));
      });
      req.on('error', (err) => {
        body?.destroy();
        reject(this.#networkError(err));
      });
      if (!body) {
        req.end();
        return;
      }
      body.on('error', (err) => {
        // A local read error, not a network one: report it as it is.
        reject(err);
        req.destroy();
      });
      body.pipe(req);
    });
  }

  #networkError(err) {
    // With several addresses to try (::1 and 127.0.0.1 for localhost) the
    // error is an AggregateError whose own message may be empty.
    const detail = err.errors?.length ? err.errors.map((e) => e.message).join('; ') : err.message || err.code;
    return new RequestError(`cannot reach server ${this.server.href}: ${detail}`);
  }
}

/**
 * Percent-encodes a key for use in a URL path. Each segment is encoded on its
 * own so the "/" separators stay as they are.
 *
 * @param {string} key
 * @returns {string}
 */
export function encodeKey(key) {
  return key.split('/').map(encodeURIComponent).join('/');
}

function describeFailure(res) {
  const text = res.body.toString('utf8');
  let detail;
  try {
    detail = JSON.parse(text)?.error ?? text;
  } catch {
    detail = text;
  }
  detail = String(detail).trim().slice(0, 200);
  return `server answered ${res.status} ${res.statusText}${detail ? ` (${detail})` : ''}`;
}
