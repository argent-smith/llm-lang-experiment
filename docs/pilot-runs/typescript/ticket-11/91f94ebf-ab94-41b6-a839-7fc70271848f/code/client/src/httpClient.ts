export interface RemoteBlobMeta {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
}

const REQUEST_TIMEOUT_MS = 10_000;

function joinUrl(server: string, pathname: string): string {
  return `${server.replace(/\/+$/, "")}${pathname}`;
}

/**
 * Turns a fetch() rejection into a message that names the actual cause
 * (refused, unresolvable host, reset, timeout) instead of undici's generic
 * "fetch failed" — the spec requires the client to say why the server was
 * unreachable, not just that it was.
 */
function describeConnectionError(
  err: unknown,
  server: string,
  timeoutMs: number
): string {
  const error = err as Error & { cause?: NodeJS.ErrnoException };

  if (error.name === "TimeoutError" || error.name === "AbortError") {
    return `timed out waiting for ${server} (no response within ${timeoutMs}ms)`;
  }

  switch (error.cause?.code) {
    case "ECONNREFUSED":
      return `connection to ${server} refused (is the server running?)`;
    case "ENOTFOUND":
    case "EAI_AGAIN":
      return `could not resolve host for ${server}`;
    case "ECONNRESET":
      return `connection to ${server} was reset while communicating`;
    default:
      return `could not reach ${server}: ${error.cause?.message ?? error.message}`;
  }
}

/**
 * Encodes a key for use in a /blobs/{key} URL: each path segment is
 * percent-encoded individually and rejoined with literal "/", so the
 * server's single decodeURIComponent(rawTail) call reconstructs the exact
 * original key instead of mangling `/` embedded inside a segment.
 */
export function encodeKeyPath(key: string): string {
  return key
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  server: string
): Promise<Response> {
  try {
    return await fetch(url, {
      ...init,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (err) {
    throw new Error(describeConnectionError(err, server, REQUEST_TIMEOUT_MS));
  }
}

export async function listRemoteBlobs(
  server: string
): Promise<RemoteBlobMeta[]> {
  const url = joinUrl(server, "/blobs");
  const res = await fetchWithTimeout(url, { method: "GET" }, server);

  if (!res.ok) {
    throw new Error(
      `GET /blobs failed: server responded ${res.status} ${res.statusText}`
    );
  }
  return (await res.json()) as RemoteBlobMeta[];
}

export async function downloadBlob(
  server: string,
  key: string
): Promise<Buffer> {
  const url = joinUrl(server, `/blobs/${encodeKeyPath(key)}`);
  const res = await fetchWithTimeout(url, { method: "GET" }, server);

  if (!res.ok) {
    throw new Error(
      `GET /blobs/${key} failed: server responded ${res.status} ${res.statusText}`
    );
  }
  return Buffer.from(await res.arrayBuffer());
}

export async function uploadBlob(
  server: string,
  key: string,
  content: Buffer
): Promise<void> {
  const url = joinUrl(server, `/blobs/${encodeKeyPath(key)}`);
  const res = await fetchWithTimeout(
    url,
    { method: "PUT", body: content },
    server
  );

  if (!res.ok) {
    throw new Error(
      `PUT /blobs/${key} failed: server responded ${res.status} ${res.statusText}`
    );
  }
}
