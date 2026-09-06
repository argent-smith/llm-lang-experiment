'use strict';

// Ceiling on how long any single HTTP call to the server may take, from
// opening the connection through receiving the full response. Without an
// explicit limit, a server whose hostname never resolves, that is slow to
// refuse a connection, or that accepts the connection and then never
// answers, would hang the client forever instead of failing with a clear
// error.
const DEFAULT_TIMEOUT_MS = 10000;

// fetch() only ever rejects with a generic "fetch failed" TypeError (or, on
// our own timeout signal, an Abort/TimeoutError) -- the actual reason (DNS
// failure, refused connection, reset, timeout) lives in `.cause`/`.name`.
// This turns that into a short, specific phrase for the message shown to
// the user.
function describeNetworkError(err) {
  if (err.name === 'AbortError' || err.name === 'TimeoutError') {
    return 'timed out waiting for the server';
  }
  const code = err.cause && err.cause.code;
  switch (code) {
    case 'ECONNREFUSED':
      return 'connection refused';
    case 'ENOTFOUND':
    case 'EAI_AGAIN':
      return 'server hostname could not be resolved';
    case 'ECONNRESET':
      return 'connection reset';
    case 'ETIMEDOUT':
      return 'connection timed out';
    default:
      return (err.cause && err.cause.message) || err.message;
  }
}

// Performs one HTTP call to the server under a hard timeout, normalizing any
// network-level failure (unreachable host, DNS, timeout) into a single clear
// error. An HTTP error status (4xx/5xx) is not a network failure: it
// resolves normally here, and callers check `res.ok` themselves, since (for
// example) a 500 on one key out of many should fail only that key, not look
// like the server being unreachable.
async function request(server, path, options, timeoutMs = DEFAULT_TIMEOUT_MS) {
  try {
    return await fetch(`${server}${path}`, { ...options, signal: AbortSignal.timeout(timeoutMs) });
  } catch (err) {
    throw new Error(`cannot reach server at ${server}: ${describeNetworkError(err)}`);
  }
}

// Fetches the server's full blob listing (GET /blobs) as a Map keyed by
// blob key. Shared by push, pull, sync and status, which all need to diff
// the local directory against this same listing.
async function fetchServerBlobs(server, timeoutMs) {
  const res = await request(server, '/blobs', {}, timeoutMs);
  if (!res.ok) {
    throw new Error(`GET /blobs failed: ${res.status} ${res.statusText}`);
  }
  const items = await res.json();
  const map = new Map();
  for (const item of items) map.set(item.key, item);
  return map;
}

module.exports = { fetchServerBlobs, request, describeNetworkError, DEFAULT_TIMEOUT_MS };
