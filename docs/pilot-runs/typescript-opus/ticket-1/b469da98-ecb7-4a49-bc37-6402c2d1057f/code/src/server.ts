import { constants as fsConstants } from "node:fs";
import { access, mkdir, stat } from "node:fs/promises";
import http from "node:http";
import type { AddressInfo } from "node:net";

import type { ServerConfig } from "./config.js";

export interface RunningServer {
  readonly server: http.Server;
  /** Actual port the server is bound to (useful when started with port 0). */
  readonly port: number;
  /** Stops accepting connections and waits for in-flight requests to finish. */
  close(): Promise<void>;
}

export interface StartOptions {
  /** Interface to bind; defaults to all interfaces. */
  host?: string;
  /** How long close() waits for in-flight requests before dropping them. */
  shutdownTimeoutMs?: number;
}

/**
 * Makes sure the data directory exists and is a writable directory, so that
 * misconfiguration is reported at startup rather than on the first request.
 */
export async function prepareDataDir(dataDir: string): Promise<void> {
  await mkdir(dataDir, { recursive: true });
  const info = await stat(dataDir);
  if (!info.isDirectory()) {
    throw new Error(`data dir is not a directory: ${dataDir}`);
  }
  await access(dataDir, fsConstants.R_OK | fsConstants.W_OK);
}

export function createRequestHandler(_config: ServerConfig): http.RequestListener {
  return (req, res) => {
    try {
      route(req, res);
    } catch (err) {
      console.error("unhandled error while serving request:", err);
      if (!res.headersSent) {
        sendJson(res, 500, { error: "internal server error" });
      } else {
        res.destroy();
      }
    }
  };
}

function route(req: http.IncomingMessage, res: http.ServerResponse): void {
  // Raw path without the query string. Deliberately not normalized via URL:
  // blob keys (future tickets) must be validated as sent, not after the
  // dot segments have been silently resolved.
  const path = (req.url ?? "").split("?", 1)[0];

  if (path === "/healthz") {
    if (req.method === "GET" || req.method === "HEAD") {
      sendJson(res, 200, { status: "ok" });
    } else {
      res.setHeader("Allow", "GET, HEAD");
      sendJson(res, 405, { error: "method not allowed" });
    }
    return;
  }

  sendJson(res, 404, { error: "not found" });
}

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

export async function startServer(config: ServerConfig, options: StartOptions = {}): Promise<RunningServer> {
  await prepareDataDir(config.dataDir);

  const server = http.createServer(createRequestHandler(config));

  // Malformed HTTP must never take the process down: answer 400 and drop
  // the connection.
  server.on("clientError", (err: NodeJS.ErrnoException, socket) => {
    if (err.code === "ECONNRESET" || !socket.writable) {
      socket.destroy();
      return;
    }
    socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    const onListening = (): void => {
      server.off("error", reject);
      resolve();
    };
    if (options.host === undefined) {
      server.listen(config.port, onListening);
    } else {
      server.listen(config.port, options.host, onListening);
    }
  });

  const shutdownTimeoutMs = options.shutdownTimeoutMs ?? 5000;
  let closing: Promise<void> | undefined;

  return {
    server,
    port: (server.address() as AddressInfo).port,
    close() {
      closing ??= new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => server.closeAllConnections(), shutdownTimeoutMs);
        timer.unref();
        server.close((err) => {
          clearTimeout(timer);
          if (err) reject(err);
          else resolve();
        });
        server.closeIdleConnections();
      });
      return closing;
    },
  };
}
