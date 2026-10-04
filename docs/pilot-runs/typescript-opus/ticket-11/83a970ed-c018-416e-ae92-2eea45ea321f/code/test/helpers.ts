// Shared fixtures for the client tests: real servers, file trees, the CLI.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdir, writeFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { BlobStore } from "../src/blobs.js";
import { SyncboxClient } from "../src/client.js";
import { push, type Reporter } from "../src/push.js";
import { createRequestHandler } from "../src/server.js";

// Tests run from dist/test/; the `syncbox` launcher is copied to bin/.
export const SYNCBOX = fileURLToPath(new URL("../../bin/syncbox", import.meta.url));

export const sha256 = (data: string | Buffer): string => createHash("sha256").update(data).digest("hex");

export interface TestServer {
  url: URL;
  dataDir: string;
  /** `METHOD /path` of every request received. */
  requests: string[];
  /** Gets each request first; returning true means it has taken care of it. */
  intercept?: ((req: http.IncomingMessage, res: http.ServerResponse) => boolean) | undefined;
  close(): Promise<void>;
}

/** A real Syncbox server that also records the requests it gets. */
export async function startServer(dataDir: string, port = 0): Promise<TestServer> {
  await mkdir(dataDir, { recursive: true });
  const store = new BlobStore(dataDir);
  await store.init();
  const handler = createRequestHandler(store);
  const requests: string[] = [];
  const server = http.createServer((req, res) => {
    requests.push(`${req.method} ${req.url}`);
    if (test.intercept?.(req, res)) return;
    handler(req, res);
  });
  server.listen(port, "127.0.0.1");
  await once(server, "listening");
  const address = server.address() as net.AddressInfo;
  const test: TestServer = {
    url: new URL(`http://127.0.0.1:${address.port}/`),
    dataDir,
    requests,
    async close() {
      server.closeAllConnections();
      server.close();
      await once(server, "close");
    },
  };
  return test;
}

/** A TCP server that accepts connections and immediately drops them. */
export async function startDroppingServer(): Promise<{ url: URL; close(): void }> {
  const server = net.createServer((socket) => socket.destroy());
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address() as net.AddressInfo;
  return { url: new URL(`http://127.0.0.1:${port}/`), close: () => server.close() };
}

export async function freePort(): Promise<number> {
  const srv = net.createServer();
  srv.listen(0, "127.0.0.1");
  await once(srv, "listening");
  const { port } = srv.address() as net.AddressInfo;
  srv.close();
  await once(srv, "close");
  return port;
}

export async function writeTree(root: string, files: Record<string, string | Buffer>): Promise<void> {
  for (const [key, content] of Object.entries(files)) {
    const path = join(root, ...key.split("/"));
    await mkdir(join(path, ".."), { recursive: true });
    await writeFile(path, content);
  }
}

/** Seeds the server with `files` by pushing them from a scratch directory. */
export async function seed(server: TestServer, scratch: string, files: Record<string, string | Buffer>): Promise<void> {
  await writeTree(scratch, files);
  const client = new SyncboxClient(server.url);
  try {
    await push(scratch, client, collectingReporter());
  } finally {
    client.close();
  }
}

export async function remoteBlobs(server: TestServer): Promise<Map<string, string>> {
  const client = new SyncboxClient(server.url);
  try {
    return new Map((await client.list()).map((b) => [b.key, b.sha256]));
  } finally {
    client.close();
  }
}

export function collectingReporter(): Reporter & { info_: string[]; warn_: string[] } {
  const info_: string[] = [];
  const warn_: string[] = [];
  return { info_, warn_, info: (l) => info_.push(l), warn: (l) => warn_.push(l) };
}

export interface Result {
  code: number | null;
  stdout: string;
  stderr: string;
}

export function runSyncbox(args: string[], env: NodeJS.ProcessEnv = {}): Promise<Result> {
  // Clean environment, so a SYNCBOX_SERVER from the outside can't leak in.
  const child = spawn(SYNCBOX, args, { env: { PATH: process.env.PATH, ...env }, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (c: string) => (stdout += c));
  child.stderr.setEncoding("utf8").on("data", (c: string) => (stderr += c));
  return once(child, "exit").then(([code]) => ({ code: code as number | null, stdout, stderr }));
}
