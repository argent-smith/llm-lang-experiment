import { createHash } from "node:crypto";
import http from "node:http";
import https from "node:https";
import { Transform, type Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

/** A failure to report to the user as is (no stack trace). */
export class ClientError extends Error {
  override name = "ClientError";

  constructor(
    message: string,
    /** No connection to the server could be made: further requests are bound to fail alike. */
    readonly unreachable = false,
  ) {
    super(message);
  }
}

export interface RemoteBlob {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
}

/** How long to wait for a connection to the server (host name lookup included). */
const CONNECT_TIMEOUT_MS = 10_000;
/**
 * How long a request may go with nothing sent or received before it is
 * given up. A server that is merely slow to take in an upload or to send a
 * body keeps it going however long that takes; one that falls silent doesn't.
 */
const RESPONSE_TIMEOUT_MS = 30_000;

/** Fixed in the CLI; adjustable here so that tests needn't wait that long. */
export interface ClientOptions {
  connectTimeoutMs?: number;
  responseTimeoutMs?: number;
}

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
  private readonly connectTimeoutMs: number;
  private readonly responseTimeoutMs: number;

  constructor(
    readonly server: URL,
    options: ClientOptions = {},
  ) {
    const Agent = server.protocol === "https:" ? https.Agent : http.Agent;
    this.agent = new Agent({ keepAlive: true });
    this.connectTimeoutMs = options.connectTimeoutMs ?? CONNECT_TIMEOUT_MS;
    this.responseTimeoutMs = options.responseTimeoutMs ?? RESPONSE_TIMEOUT_MS;
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

  /**
   * Downloads the blob stored under `key`. Resolves once the server has
   * answered 200, with the body still to be received: it has to be consumed
   * right away, chunk by chunk. Failures while receiving it are thrown from
   * the iteration as ClientError.
   */
  async get(key: string): Promise<AsyncIterable<Buffer>> {
    const what = `GET ${key}`;
    const res = await this.send(what, "GET", blobUrl(this.server, key));
    if (res.statusCode !== 200) {
      throw unexpectedStatus(what, await this.receive(what, res));
    }
    return this.chunks(what, res);
  }

  /** Sends a request and reads the whole response. */
  private async request(what: string, method: string, url: URL, body?: Readable, via?: Transform): Promise<HttpResponse> {
    return this.receive(what, await this.send(what, method, url, body, via));
  }

  private async receive(what: string, res: http.IncomingMessage): Promise<HttpResponse> {
    const chunks: Buffer[] = [];
    for await (const chunk of this.chunks(what, res)) {
      chunks.push(chunk);
    }
    return { status: res.statusCode ?? 0, statusText: res.statusMessage ?? "", body: Buffer.concat(chunks) };
  }

  private async *chunks(what: string, res: http.IncomingMessage): AsyncGenerator<Buffer> {
    try {
      for await (const chunk of res) {
        yield chunk as Buffer;
      }
    } catch (err) {
      throw this.failed(what, err);
    }
    if (!res.complete) {
      throw this.failed(what, new Error("connection closed before the response was complete"));
    }
  }

  /**
   * Sends a request, streaming `body` through `via` (if given) into it, and
   * resolves with the response as soon as its headers are in. Neither an
   * unreachable nor a silent server makes it hang: see CONNECT_TIMEOUT_MS
   * and RESPONSE_TIMEOUT_MS.
   */
  private send(what: string, method: string, url: URL, body?: Readable, via?: Transform): Promise<http.IncomingMessage> {
    return new Promise<http.IncomingMessage>((resolve, reject) => {
      let connected = false;
      let response: http.IncomingMessage | undefined;
      // The first failure tells what happened: once the request is torn
      // down, the upload stream is destroyed with its error, and so on.
      let failure: ClientError | undefined;
      const fail = (err: unknown): void => {
        failure ??= this.failed(what, err, connected, body);
        req.destroy();
        reject(failure);
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
          response = res;
          // Errors reach whoever reads the body (through the stream's state);
          // this only keeps one that comes before reading starts, or after it
          // was abandoned, from being an uncaught 'error' event.
          res.on("error", () => {});
          resolve(res);
        },
      );
      req.on("error", fail);

      req.on("socket", (socket) => {
        // A kept-alive connection is reused as is.
        if (!socket.connecting) {
          connected = true;
          return;
        }
        const timer = setTimeout(
          () => fail(new Error(`timed out after ${this.connectTimeoutMs / 1000}s`)),
          this.connectTimeoutMs,
        );
        socket.once("connect", () => {
          connected = true;
          clearTimeout(timer);
        });
        socket.once("close", () => clearTimeout(timer));
      });

      // Until there is a connection, the timer above is in charge. From then
      // on this one runs, also while the response body is being read.
      req.setTimeout(this.responseTimeoutMs, () => {
        if (!connected) return;
        const err = new ClientError(
          `${what}: no response from ${this.server.origin}: nothing received for ${this.responseTimeoutMs / 1000}s`,
        );
        // Whoever is reading the body gets this reason, not just "aborted".
        response?.destroy(err);
        fail(err);
      });

      if (body === undefined) {
        req.end();
      } else {
        const upload = via === undefined ? pipeline(body, req) : pipeline(body, via, req);
        upload.catch(fail);
      }
    });
  }

  /**
   * Says why a request failed: the server couldn't be reached at all (no
   * connection), the file being uploaded couldn't be read, or the exchange
   * with the server broke off.
   */
  private failed(what: string, err: unknown, connected = true, upload?: Readable): ClientError {
    if (err instanceof ClientError) return err;
    if (upload?.errored) {
      return new ClientError(`${what}: cannot read the file to upload: ${describeError(upload.errored, this.server)}`);
    }
    if (!connected) {
      return new ClientError(`${what}: cannot connect to ${this.server.origin}: ${describeError(err, this.server)}`, true);
    }
    return new ClientError(`${what}: request to ${this.server.origin} failed: ${describeError(err, this.server)}`);
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

/** What the errno codes a request typically fails with mean. */
const NETWORK_ERRORS: Record<string, string> = {
  ECONNREFUSED: "connection refused",
  ECONNRESET: "connection reset by the server",
  EPIPE: "connection closed by the server",
  ETIMEDOUT: "connection timed out",
  EHOSTUNREACH: "host unreachable",
  EHOSTDOWN: "host is down",
  ENETUNREACH: "network unreachable",
  EADDRNOTAVAIL: "address not available",
};

/**
 * A readable reason for a failed request, with the errno code to go with it.
 * With several addresses to try (localhost → ::1 and 127.0.0.1), connect
 * errors come as an AggregateError without a message of its own.
 */
function describeError(err: unknown, server: URL): string {
  if (err instanceof AggregateError && err.errors.length > 0) {
    return describeError(err.errors[0], server);
  }
  if (!(err instanceof Error)) {
    return String(err);
  }
  const code = (err as NodeJS.ErrnoException).code;
  const withCode = (reason: string): string => (code === undefined ? reason : `${reason} (${code})`);
  if (err.message === "socket hang up") {
    return withCode("the server closed the connection without responding");
  }
  if (code === "ENOTFOUND") {
    return withCode(`host name ${server.hostname} not found`);
  }
  if (code === "EAI_AGAIN" || code === "EAI_FAIL" || code === "EAI_NODATA") {
    return withCode(`host name ${server.hostname} could not be resolved`);
  }
  const known = code === undefined ? undefined : NETWORK_ERRORS[code];
  if (known !== undefined) {
    return withCode(known);
  }
  return err.message || (code ?? err.name);
}
