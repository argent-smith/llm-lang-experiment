'use strict';

// Fetches the server's full blob listing (GET /blobs) as a Map keyed by
// blob key. Shared by push and pull, which both need to diff the local
// directory against this same listing.
async function fetchServerBlobs(server) {
  let res;
  try {
    res = await fetch(`${server}/blobs`);
  } catch (err) {
    throw new Error(`cannot reach server at ${server}: ${err.message}`);
  }
  if (!res.ok) {
    throw new Error(`GET /blobs failed: ${res.status} ${res.statusText}`);
  }
  const items = await res.json();
  const map = new Map();
  for (const item of items) map.set(item.key, item);
  return map;
}

module.exports = { fetchServerBlobs };
