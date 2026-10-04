// HTTP client for the Syncbox server API (see syncbox-openapi.yaml).
//
// Built on node:http rather than fetch(): fetch refuses a list of "bad
// ports" (6000, 10080, ...) that a Syncbox server may well listen on.

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { pipeline } from 'node:stream/promises';

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
   * @param {{ signal?: AbortSignal }} [options]  aborting rejects with an AbortError
   * @returns {Promise<Array<{ key: string, sha256: string, size: number, modified_at: string }>>}
   * @throws {RequestError}
   */
  async list({ signal } = {}) {
    const res = await this.#request('GET', `${this.base}/blobs`, { signal });
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
   * Downloads the blob `key` into `destination`, which is ended once the
   * whole blob has been written to it.
   *
   * @param {string} key
   * @param {import('node:stream').Writable} destination
   * @param {{ signal?: AbortSignal }} [options]  aborting rejects with an AbortError
   * @returns {Promise<{ sha256: string, size: number }>} of the bytes received
   * @throws {RequestError} if the server cannot be reached or refuses, or the
   *   connection breaks off mid-download
   * @throws {Error} if writing to `destination` fails
   */
  async download(key, destination, { signal } = {}) {
    const res = await this.#send('GET', `${this.base}/blobs/${encodeKey(key)}`, { signal });
    if (res.statusCode !== 200) {
      throw new RequestError(`GET ${key}: ${describeFailure(await this.#readBody(res))}`);
    }
    const hash = createHash('sha256');
    let size = 0;
    // Errors are translated here, where they can only come from the
    // network; pipeline() also sees the destination's own errors.
    async function* received() {
      try {
        for await (const chunk of res) {
          hash.update(chunk);
          size += chunk.length;
          yield chunk;
        }
      } catch (err) {
        if (err.name === 'AbortError') {
          throw err;
        }
        throw new RequestError(`GET ${key}: download interrupted: ${err.message || err.code}`);
      }
    }
    await pipeline(received, destination, { signal });
    return { sha256: hash.digest('hex'), size };
  }

  /**
   * @param {string} method
   * @param {string} url
   * @param {{ headers?: Record<string, string>, body?: import('node:stream').Readable }} [options]
   * @returns {Promise<{ status: number, statusText: string, body: Buffer }>}
   */
  async #request(method, url, options = {}) {
    const res = await this.#readBody(await this.#send(method, url, options));
    // The server may answer (e.g. 400) without reading the whole body.
    options.body?.destroy();
    return res;
  }

  /**
   * @param {import('node:http').IncomingMessage} res
   * @returns {Promise<{ status: number, statusText: string, body: Buffer }>}
   */
  #readBody(res) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        resolve({ status: res.statusCode, statusText: res.statusMessage, body: Buffer.concat(chunks) });
      });
      res.on('error', (err) => reject(err.name === 'AbortError' ? err : this.#networkError(err)));
    });
  }

  /**
   * Sends a request; resolves as soon as the response headers are in,
   * leaving the response body to the caller.
   *
   * @param {string} method
   * @param {string} url
   * @param {{ headers?: Record<string, string>, body?: import('node:stream').Readable, signal?: AbortSignal }} [options]
   * @returns {Promise<import('node:http').IncomingMessage>}
   */
  #send(method, url, { headers = {}, body, signal } = {}) {
    return new Promise((resolve, reject) => {
      const transport = url.startsWith('https:') ? https : http;
      const req = transport.request(url, { method, headers, signal }, resolve);
      req.on('error', (err) => {
        body?.destroy();
        reject(err.name === 'AbortError' ? err : this.#networkError(err));
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
