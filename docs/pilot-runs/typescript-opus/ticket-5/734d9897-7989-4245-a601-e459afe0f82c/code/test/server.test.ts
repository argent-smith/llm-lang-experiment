import assert from "node:assert/strict";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";

import { startServer, type RunningServer } from "../src/server.js";

async function tempDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), "syncbox-test-"));
}

/** Sends raw bytes over TCP and returns whatever the server answers. */
function rawRequest(port: number, payload: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1");
    let response = "";
    socket.setEncoding("latin1");
    socket.on("data", (chunk) => (response += chunk));
    socket.on("end", () => resolve(response));
    socket.on("error", reject);
    socket.write(payload);
  });
}

describe("HTTP server", () => {
  let root: string;
  let running: RunningServer;
  let base: string;

  before(async () => {
    root = await tempDir();
    running = await startServer({ dataDir: join(root, "data"), port: 0 }, { host: "127.0.0.1" });
    base = `http://127.0.0.1:${running.port}`;
  });

  after(async () => {
    await running.close();
    await rm(root, { recursive: true, force: true });
  });

  it("GET /healthz returns 200", async () => {
    const res = await fetch(`${base}/healthz`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: "ok" });
  });

  it("GET /healthz ignores the query string", async () => {
    const res = await fetch(`${base}/healthz?probe=1`);
    assert.equal(res.status, 200);
    await res.body?.cancel();
  });

  it("HEAD /healthz returns 200 without a body", async () => {
    const res = await fetch(`${base}/healthz`, { method: "HEAD" });
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "");
  });

  it("rejects other methods on /healthz with 405", async () => {
    const res = await fetch(`${base}/healthz`, { method: "POST" });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "GET, HEAD");
    await res.body?.cancel();
  });

  it("returns 404 for unknown paths", async () => {
    for (const path of ["/", "/nope", "/healthz/", "/healthz/extra"]) {
      const res = await fetch(`${base}${path}`);
      assert.equal(res.status, 404, path);
      await res.body?.cancel();
    }
  });

  it("answers malformed HTTP with 400 and keeps serving", async () => {
    const response = await rawRequest(running.port, "THIS IS NOT HTTP\r\n\r\n");
    assert.match(response, /^HTTP\/1\.1 400 /);
    const res = await fetch(`${base}/healthz`);
    assert.equal(res.status, 200);
    await res.body?.cancel();
  });

  it("creates the data dir on startup", async () => {
    assert.ok((await stat(join(root, "data"))).isDirectory());
  });
});

describe("startServer", () => {
  it("creates nested data dirs", async () => {
    const root = await tempDir();
    try {
      const dataDir = join(root, "a", "b", "c");
      const running = await startServer({ dataDir, port: 0 }, { host: "127.0.0.1" });
      await running.close();
      assert.ok((await stat(dataDir)).isDirectory());
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("fails when the data dir path is a regular file", async () => {
    const root = await tempDir();
    try {
      const file = join(root, "file");
      await writeFile(file, "x");
      await assert.rejects(startServer({ dataDir: file, port: 0 }, { host: "127.0.0.1" }));
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("fails when the port is already in use", async () => {
    const root = await tempDir();
    const first = await startServer({ dataDir: root, port: 0 }, { host: "127.0.0.1" });
    try {
      await assert.rejects(startServer({ dataDir: root, port: first.port }, { host: "127.0.0.1" }), {
        code: "EADDRINUSE",
      });
    } finally {
      await first.close();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("close() is idempotent", async () => {
    const root = await tempDir();
    try {
      const running = await startServer({ dataDir: root, port: 0 }, { host: "127.0.0.1" });
      await Promise.all([running.close(), running.close()]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
