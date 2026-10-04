// HTTP client for the Syncbox server API (see syncbox-openapi.yaml).
//
// Built on node:http rather than fetch(): fetch refuses a list of "bad
// ports" (6000, 10080, ...) that a Syncbox server may well listen on.

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { pipeline } from 'node:stream/promises';

// How long a request may wait on the server before it fails. Every request
// has both limits, so nothing waits indefinitely.
/** To connect, host name lookup included. */
export const CONNECT_TIMEOUT_MS = 10_000;
/** Once connected: with not a byte going either way, e.g. while waiting for the response. */
export const RESPONSE_TIMEOUT_MS = 30_000;

/** A request that failed: the server could not be reached, broke off, or answered with an error. */
export class RequestError extends Error {
  /**
   * @param {string} message
   * @param {{ reason?: string }} [options]  `reason`: what went wrong, without
   *   the request it happened to (the "PUT a.txt: " of the message)
   */
  constructor(message, { reason = message } = {}) {
    super(message);
    this.name = 'RequestError';
    this.reason = reason;
  }
}

/**
 * The server could not be reached at all: no connection could be made
 * (refused, host not found, timed out). Further requests are bound to fail
 * the same way.
 */
export class UnreachableError extends RequestError {
  constructor(message) {
    super(message);
    this.name = 'UnreachableError';
  }
}

function requestError(operation, reason) {
  return new RequestError(`${operation}: ${reason}`, { reason });
}

export class SyncboxClient {
  /**
   * @param {URL} server  base URL; may include a path prefix
   * @param {{ connectTimeout?: number, responseTimeout?: number }} [timeouts]
   *   in ms; CONNECT_TIMEOUT_MS and RESPONSE_TIMEOUT_MS unless given
   */
  constructor(server, { connectTimeout = CONNECT_TIMEOUT_MS, responseTimeout = RESPONSE_TIMEOUT_MS } = {}) {
    this.server = server;
    // Without the trailing slash, so that appending "/blobs" works for both
    // http://host:8080 and http://host/prefix/.
    this.base = server.origin + server.pathname.replace(/\/+$/, '');
    this.connectTimeout = connectTimeout;
    this.responseTimeout = responseTimeout;
  }

  /**
   * Lists blobs stored on the server.
   *
   * @param {{ signal?: AbortSignal }} [options]  aborting rejects with an AbortError
   * @returns {Promise<Array<{ key: string, sha256: string, size: number, modified_at: string }>>}
   * @throws {UnreachableError} if the server cannot be reached
   * @throws {RequestError} if the request fails otherwise
   */
  async list({ signal } = {}) {
    const operation = 'GET /blobs';
    const res = await this.#request('GET', `${this.base}/blobs`, operation, { signal });
    if (res.status !== 200) {
      throw requestError(operation, describeFailure(res));
    }
    let blobs;
    try {
      blobs = JSON.parse(res.body.toString('utf8'));
    } catch (err) {
      throw requestError(operation, `response is not valid JSON: ${err.message}`);
    }
    if (!Array.isArray(blobs) || !blobs.every((b) => typeof b?.key === 'string' && typeof b?.sha256 === 'string')) {
      throw requestError(operation, 'response is not a list of blobs');
    }
    return blobs;
  }

  /**
   * Uploads the contents of a local file as the blob `key`, replacing any
   * blob already stored under it.
   *
   * @param {string} key
   * @param {string} file  path of the local file
   * @param {{ signal?: AbortSignal }} [options]  aborting rejects with an
   *   AbortError; the server discards the unfinished upload
   * @returns {Promise<{ key: string, sha256: string, size: number }>}
   * @throws {UnreachableError} if the server cannot be reached
   * @throws {RequestError} if the upload fails otherwise or is rejected
   * @throws {Error} if the file cannot be read
   */
  async put(key, file, { signal } = {}) {
    const operation = `PUT ${key}`;
    // Sent chunked rather than with a Content-Length taken from stat(): a
    // file that shrinks while being read would leave the server waiting for
    // bytes that never come.
    const res = await this.#request('PUT', `${this.base}/blobs/${encodeKey(key)}`, operation, {
      headers: { 'Content-Type': 'application/octet-stream' },
      body: fs.createReadStream(file),
      signal,
    });
    if (res.status !== 201) {
      throw requestError(operation, describeFailure(res));
    }
    try {
      return JSON.parse(res.body.toString('utf8'));
    } catch (err) {
      throw requestError(operation, `response is not valid JSON: ${err.message}`);
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
   * @throws {UnreachableError} if the server cannot be reached
   * @throws {RequestError} if the server refuses, or the connection breaks
   *   off or stalls mid-download
   * @throws {Error} if writing to `destination` fails
   */
  async download(key, destination, { signal } = {}) {
    const operation = `GET ${key}`;
    const res = await this.#send('GET', `${this.base}/blobs/${encodeKey(key)}`, operation, { signal });
    if (res.statusCode !== 200) {
      throw requestError(operation, describeFailure(await this.#readBody(res, operation)));
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
        // A timeout is a RequestError already, saying what happened.
        if (err.name === 'AbortError' || err instanceof RequestError) {
          throw err;
        }
        throw requestError(operation, `download interrupted: ${describeNetworkError(err)}`);
      }
    }
    await pipeline(received, destination, { signal });
    return { sha256: hash.digest('hex'), size };
  }

  /**
   * @param {string} method
   * @param {string} url
   * @param {string} operation  names the request in errors, e.g. "PUT a.txt"
   * @param {{ headers?: Record<string, string>, body?: import('node:stream').Readable, signal?: AbortSignal }} [options]
   * @returns {Promise<{ status: number, statusText: string, body: Buffer }>}
   */
  async #request(method, url, operation, options = {}) {
    const res = await this.#readBody(await this.#send(method, url, operation, options), operation);
    // The server may answer (e.g. 400) without reading the whole body.
    options.body?.destroy();
    return res;
  }

  /**
   * @param {import('node:http').IncomingMessage} res
   * @param {string} operation
   * @returns {Promise<{ status: number, statusText: string, body: Buffer }>}
   */
  #readBody(res, operation) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        resolve({ status: res.statusCode, statusText: res.statusMessage, body: Buffer.concat(chunks) });
      });
      res.on('error', (err) => reject(this.#networkError(err, operation, true)));
    });
  }

  /**
   * Sends a request; resolves as soon as the response headers are in,
   * leaving the response body to the caller.
   *
   * Fails with an UnreachableError if no connection is made within
   * `connectTimeout`, and with a RequestError if, once connected, nothing
   * goes either way for `responseTimeout`; the latter holds until the
   * response body has been read.
   *
   * @param {string} method
   * @param {string} url
   * @param {string} operation  names the request in errors
   * @param {{ headers?: Record<string, string>, body?: import('node:stream').Readable, signal?: AbortSignal }} [options]
   * @returns {Promise<import('node:http').IncomingMessage>}
   */
  #send(method, url, operation, { headers = {}, body, signal } = {}) {
    return new Promise((resolve, reject) => {
      const transport = url.startsWith('https:') ? https : http;
      let connected = false;
      let response;
      const req = transport.request(url, { method, headers, signal }, (res) => {
        response = res;
        resolve(res);
      });
      // Once the response has started, whoever reads it gets the error.
      const giveUp = (err) => (response ?? req).destroy(err);

      const connectTimer = setTimeout(() => {
        giveUp(new UnreachableError(`cannot reach server ${this.server.href}: no connection within ${duration(this.connectTimeout)} (timed out)`));
      }, this.connectTimeout);
      const onConnect = () => {
        connected = true;
        clearTimeout(connectTimer);
        req.setTimeout(this.responseTimeout, () => {
          const reason = response === undefined
            ? `timed out: no response from the server within ${duration(this.responseTimeout)}`
            : `timed out: the server sent nothing for ${duration(this.responseTimeout)}`;
          giveUp(requestError(operation, reason));
        });
      };
      req.on('socket', (socket) => {
        if (!socket.pending) {
          // Kept alive from an earlier request.
          onConnect();
        } else if (socket.connecting) {
          socket.once('connect', onConnect);
        }
        // Otherwise connecting has failed already, and the error is on its way.
      });
      req.on('close', () => clearTimeout(connectTimer));

      req.on('error', (err) => {
        body?.destroy();
        reject(this.#networkError(err, operation, connected));
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

  /**
   * @param {Error} err  as the request or the response emitted it
   * @param {string} operation
   * @param {boolean} connected  whether a connection to the server was made
   * @returns {Error}
   */
  #networkError(err, operation, connected) {
    if (err.name === 'AbortError' || err instanceof RequestError) {
      return err;
    }
    if (!connected) {
      return new UnreachableError(`cannot reach server ${this.server.href}: ${describeNetworkError(err)}`);
    }
    return requestError(operation, `request failed: ${describeNetworkError(err)}`);
  }
}

const NETWORK_ERRORS = {
  ECONNREFUSED: 'connection refused',
  ECONNRESET: 'connection reset',
  EPIPE: 'connection closed by the server',
  ENOTFOUND: 'host not found',
  EAI_AGAIN: 'host name lookup failed',
  ETIMEDOUT: 'timed out',
  EHOSTUNREACH: 'host unreachable',
  ENETUNREACH: 'network unreachable',
};

/** A network error in words, followed by the system's own message. */
function describeNetworkError(err) {
  // With several addresses to try (::1 and 127.0.0.1 for localhost) the
  // error is an AggregateError whose own message may be empty.
  const all = err.errors?.length ? err.errors : [err];
  const detail = all.map((e) => e.message || e.code).join('; ');
  const what = NETWORK_ERRORS[err.code ?? all[0].code];
  return what ? `${what} (${detail})` : detail;
}

function duration(ms) {
  return ms % 1000 === 0 ? `${ms / 1000} s` : `${ms} ms`;
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
