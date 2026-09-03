import type { BlobMeta } from "./storage.js";

/**
 * Applied to every outgoing request (list, upload, download) so a server
 * that never responds fails loudly instead of hanging the client forever.
 * Covers both connection setup and waiting for a response, since
 * AbortSignal.timeout bounds the whole fetch, not just one phase of it.
 */
export const DEFAULT_TIMEOUT_MS = 30_000;

export interface NetOptions {
  timeoutMs?: number;
}

/** One file's outcome when a batch operation (push/pull/sync/status) hits a per-file error. */
export interface FileFailure {
  key: string;
  message: string;
}

export function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

async function request(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  } catch (err) {
    throw new Error(describeNetworkFailure(err, timeoutMs));
  }
}

/**
 * Translates the low-level errors Node's fetch throws (a generic "fetch
 * failed" TypeError wrapping an errno-coded cause, or a TimeoutError
 * DOMException from our AbortSignal) into a message that names the actual
 * reason - connection refused, DNS failure, timeout, reset - instead of
 * leaking "fetch failed" to the user.
 */
function describeNetworkFailure(err: unknown, timeoutMs: number): string {
  if (err instanceof Error) {
    if (err.name === "TimeoutError") {
      return `timed out after ${timeoutMs}ms waiting for the server`;
    }
    const cause = (err as { cause?: unknown }).cause;
    if (cause instanceof Error) {
      switch ((cause as NodeJS.ErrnoException).code) {
        case "ECONNREFUSED":
          return "connection refused";
        case "ENOTFOUND":
        case "EAI_AGAIN":
          return "server hostname could not be resolved";
        case "ECONNRESET":
          return "connection reset by the server";
        case "EHOSTUNREACH":
        case "ENETUNREACH":
          return "network unreachable";
      }
      return cause.message;
    }
    return err.message;
  }
  return String(err);
}

export async function fetchBlobList(
  server: string,
  opts: NetOptions = {},
): Promise<BlobMeta[]> {
  const res = await request(`${server}/blobs`, {}, opts.timeoutMs ?? DEFAULT_TIMEOUT_MS);
  if (!res.ok) {
    throw new Error(`GET /blobs failed with status ${res.status}`);
  }
  return (await res.json()) as BlobMeta[];
}

export async function uploadBlob(
  server: string,
  key: string,
  content: Buffer,
  opts: NetOptions = {},
): Promise<void> {
  const res = await request(
    `${server}/blobs/${encodeKey(key)}`,
    { method: "PUT", body: content },
    opts.timeoutMs ?? DEFAULT_TIMEOUT_MS,
  );
  if (!res.ok) {
    throw new Error(`PUT /blobs/${key} failed with status ${res.status}`);
  }
}

export async function downloadBlob(
  server: string,
  key: string,
  opts: NetOptions = {},
): Promise<Buffer> {
  const res = await request(
    `${server}/blobs/${encodeKey(key)}`,
    {},
    opts.timeoutMs ?? DEFAULT_TIMEOUT_MS,
  );
  if (!res.ok) {
    throw new Error(`GET /blobs/${key} failed with status ${res.status}`);
  }
  return Buffer.from(await res.arrayBuffer());
}
