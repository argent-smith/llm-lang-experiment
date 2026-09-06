export interface RemoteBlobMeta {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
}

const REQUEST_TIMEOUT_MS = 30_000;

function joinUrl(server: string, pathname: string): string {
  return `${server.replace(/\/+$/, "")}${pathname}`;
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
    throw new Error(
      `could not reach server at ${server}: ${(err as Error).message}`
    );
  }
}

export async function listRemoteBlobs(
  server: string
): Promise<RemoteBlobMeta[]> {
  const url = joinUrl(server, "/blobs");
  const res = await fetchWithTimeout(url, { method: "GET" }, server);

  if (!res.ok) {
    throw new Error(`GET /blobs failed: server responded ${res.status}`);
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
    throw new Error(`GET /blobs/${key} failed: server responded ${res.status}`);
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
    throw new Error(`PUT /blobs/${key} failed: server responded ${res.status}`);
  }
}
