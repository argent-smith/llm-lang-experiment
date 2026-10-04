import { createHash } from "node:crypto";
import http from "node:http";
import https from "node:https";
import { Transform, type Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

/** A failure to report to the user as is (no stack trace). */
export class ClientError extends Error {
  override name = "ClientError";
}

export interface RemoteBlob {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
}

/** How long to wait for a TCP connection before giving up on the server. */
const CONNECT_TIMEOUT_MS = 10_000;

interface HttpResponse {
  status: number;
  statusText: string;
  body: Buffer;
}

/** URL of `/blobs/{key}`: each path segment percent-encoded, `/` kept. */
export function blobUrl(server: URL, key: string): URL {
  return new URL(`blobs/${key.split("/").map(encodeURIComponent).join("/")}`, server);
}

/**
 * Thin wrapper over the server's HTTP API (see syncbox-openapi.yaml). Built
 * on node:http rather than fetch(), which refuses to connect to a list of
 * "bad" ports (6000, 10080, ...) a server may well be listening on.
 */
export class SyncboxClient {
  private readonly agent: http.Agent;

  constructor(private readonly server: URL) {
    const Agent = server.protocol === "https:" ? https.Agent : http.Agent;
    this.agent = new Agent({ keepAlive: true });
  }

  /** Releases the kept-alive connections. */
  close(): void {
    this.agent.destroy();
  }

  async list(): Promise<RemoteBlob[]> {
    const what = "GET /blobs";
    const res = await this.request(what, "GET", new URL("blobs", this.server));
    if (res.status !== 200) {
      throw unexpectedStatus(what, res);
    }
    const body = parseJson(what, res);
    if (!Array.isArray(body) || !body.every(isRemoteBlob)) {
      throw new ClientError(`${what}: server returned an unexpected response`);
    }
    return body;
  }

  /**
   * Uploads `body` under `key` and checks that the server stored exactly the
   * bytes that were sent. Returns their SHA-256.
   */
  async put(key: string, body: Readable): Promise<string> {
    const what = `PUT ${key}`;
    const hash = createHash("sha256");
    const hashing = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    const res = await this.request(what, "PUT", blobUrl(this.server, key), body, hashing);
    if (res.status !== 201) {
      throw unexpectedStatus(what, res);
    }
    const stored = parseJson(what, res) as { sha256?: unknown } | null;
    const sent = hash.digest("hex");
    if (typeof stored !== "object" || stored === null || stored.sha256 !== sent) {
      throw new ClientError(`${what}: server reports a different SHA-256 than the uploaded content has`);
    }
    return sent;
  }

  /** Sends a request, streaming `body` through `via` (if given) into it. */
  private request(what: string, method: string, url: URL, body?: Readable, via?: Transform): Promise<HttpResponse> {
    return new Promise<HttpResponse>((resolve, reject) => {
      const fail = (err: unknown): void => {
        req.destroy();
        reject(err instanceof ClientError ? err : new ClientError(`${what}: request to ${this.server.origin} failed: ${describeError(err)}`));
      };

      const transport = url.protocol === "https:" ? https : http;
      const req = transport.request(
        url,
        {
          method,
          agent: this.agent,
          headers: body === undefined ? {} : { "Content-Type": "application/octet-stream" },
        },
        (res) => {
          const chunks: Buffer[] = [];
          res.on("data", (chunk: Buffer) => chunks.push(chunk));
          res.on("error", fail);
          res.on("close", () => {
            if (!res.complete) fail(new Error("connection closed before the response was complete"));
          });
          res.on("end", () =>
            resolve({ status: res.statusCode ?? 0, statusText: res.statusMessage ?? "", body: Buffer.concat(chunks) }),
          );
        },
      );
      req.on("error", fail);

      // Only the connection setup is time-limited: a server that is merely
      // slow (hashing a large store for GET /blobs, say) is not an error.
      req.on("socket", (socket) => {
        if (!socket.connecting) return;
        const timer = setTimeout(() => fail(new Error(`no connection within ${CONNECT_TIMEOUT_MS / 1000}s`)), CONNECT_TIMEOUT_MS);
        socket.once("connect", () => clearTimeout(timer));
        socket.once("close", () => clearTimeout(timer));
      });

      if (body === undefined) {
        req.end();
      } else {
        const upload = via === undefined ? pipeline(body, req) : pipeline(body, via, req);
        upload.catch(fail);
      }
    });
  }
}

function isRemoteBlob(value: unknown): value is RemoteBlob {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return typeof v.key === "string" && typeof v.size === "number" && typeof v.sha256 === "string";
}

function parseJson(what: string, res: HttpResponse): unknown {
  try {
    return JSON.parse(res.body.toString("utf8"));
  } catch {
    throw new ClientError(`${what}: server returned a response that is not valid JSON`);
  }
}

function unexpectedStatus(what: string, res: HttpResponse): ClientError {
  let detail = "";
  try {
    const parsed = JSON.parse(res.body.toString("utf8")) as { error?: unknown };
    if (typeof parsed.error === "string") detail = `: ${parsed.error}`;
  } catch {
    // Not the server's JSON error format: the status alone has to do.
  }
  return new ClientError(`${what}: server responded ${res.status} ${res.statusText}${detail}`.trimEnd());
}

/**
 * A readable reason for a failed request. With several addresses to try
 * (localhost → ::1 and 127.0.0.1), connect errors come as an AggregateError
 * without a message of its own.
 */
function describeError(err: unknown): string {
  if (err instanceof AggregateError && err.errors.length > 0) {
    return describeError(err.errors[0]);
  }
  if (err instanceof Error) {
    return err.message || ((err as NodeJS.ErrnoException).code ?? err.name);
  }
  return String(err);
}
