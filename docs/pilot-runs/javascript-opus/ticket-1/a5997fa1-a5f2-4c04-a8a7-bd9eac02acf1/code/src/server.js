import http from 'node:http';

/**
 * Creates the Syncbox HTTP server (not yet listening).
 *
 * @param {{ dataDir: string }} options
 * @returns {http.Server}
 */
export function createServer({ dataDir }) {
  const server = http.createServer((req, res) => {
    try {
      route(req, res, { dataDir });
    } catch (err) {
      console.error('unhandled error while serving %s %s:', req.method, req.url, err);
      if (!res.headersSent) {
        sendJson(res, 500, { error: 'internal server error' });
      } else {
        res.destroy();
      }
    }
  });
  return server;
}

// `ctx` carries server-wide state (dataDir) for the blob handlers.
// eslint-disable-next-line no-unused-vars
function route(req, res, ctx) {
  const path = pathOf(req.url);

  if (path === '/healthz') {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.setHeader('Allow', 'GET, HEAD');
      return sendJson(res, 405, { error: 'method not allowed' });
    }
    return sendJson(res, 200, { status: 'ok' });
  }

  return sendJson(res, 404, { error: 'not found' });
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
