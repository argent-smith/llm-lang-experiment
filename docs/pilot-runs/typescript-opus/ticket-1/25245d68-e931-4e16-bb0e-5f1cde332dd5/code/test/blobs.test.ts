import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";

import { InvalidKeyError, parseKey } from "../src/blobs.js";
import { startServer, type RunningServer } from "../src/server.js";

interface Reply {
  status: number;
  body: string;
}

const sha256 = (data: string | Buffer): string => createHash("sha256").update(data).digest("hex");

describe("parseKey", () => {
  it("accepts relative POSIX paths and percent-decodes them", () => {
    assert.equal(parseKey("0"), "0");
    assert.equal(parseKey("docs/readme.txt"), "docs/readme.txt");
    assert.equal(parseKey("a%2Fb"), "a/b");
    assert.equal(parseKey("caf%C3%A9%20menu"), "café menu");
    assert.equal(parseKey("a..b/.hidden/..."), "a..b/.hidden/...");
  });

  it("rejects traversal, absolute, empty and unrepresentable keys", () => {
    const invalid = [
      "",
      "..",
      "../x",
      "a/../../x",
      "%2e%2e/x",
      "a/%2E%2E",
      ".",
      "a/./b",
      "/abs",
      "%2Fabs",
      "a//b",
      "a/",
      "%00",
      "a%00b",
      "%",
      "%4",
      "%zz",
      "%FF",
      "%C3",
      "%ED%A0%80", // UTF-8-encoded lone surrogate
      "\xff", // raw non-UTF-8 byte as it shows up in req.url
      "a".repeat(256),
    ];
    for (const raw of invalid) {
      assert.throws(() => parseKey(raw), InvalidKeyError, JSON.stringify(raw));
    }
  });
});

describe("blob HTTP API", () => {
  let root: string;
  let dataDir: string;
  let running: RunningServer;

  /** Sends the path exactly as given (fetch would resolve dot segments). */
  function request(method: string, path: string, body?: string | Buffer): Promise<Reply> {
    return new Promise((resolve, reject) => {
      const req = http.request(
        { host: "127.0.0.1", port: running.port, method, path, headers: { "Content-Type": "application/octet-stream" } },
        (res) => {
          const chunks: Buffer[] = [];
          res.on("data", (c: Buffer) => chunks.push(c));
          res.on("end", () => resolve({ status: res.statusCode!, body: Buffer.concat(chunks).toString("utf8") }));
          res.on("error", reject);
        },
      );
      req.on("error", reject);
      req.end(body);
    });
  }

  /** Sends a request line with arbitrary bytes and returns the status code. */
  function rawStatus(method: string, pathBytes: Buffer): Promise<number> {
    return new Promise((resolve, reject) => {
      const socket = net.connect(running.port, "127.0.0.1");
      let response = "";
      socket.setEncoding("latin1");
      socket.on("data", (chunk) => (response += chunk));
      socket.on("end", () => resolve(Number(/^HTTP\/1\.1 (\d{3}) /.exec(response)?.[1] ?? NaN)));
      socket.on("error", reject);
      socket.write(
        Buffer.concat([
          Buffer.from(`${method} `),
          pathBytes,
          Buffer.from(" HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"),
        ]),
      );
    });
  }

  async function list(): Promise<Array<{ key: string; size: number; sha256: string; modified_at: string }>> {
    const res = await request("GET", "/blobs");
    assert.equal(res.status, 200);
    return JSON.parse(res.body);
  }

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-test-"));
    dataDir = join(root, "data");
    running = await startServer({ dataDir, port: 0 }, { host: "127.0.0.1" });
  });

  after(async () => {
    await running.close();
    await rm(root, { recursive: true, force: true });
  });

  it("GET /blobs returns 200 and an empty array on an empty store", async () => {
    const res = await request("GET", "/blobs");
    assert.equal(res.status, 200);
    assert.deepEqual(JSON.parse(res.body), []);
  });

  it("GET /blobs ignores the query string", async () => {
    const res = await request("GET", "/blobs?x=1");
    assert.equal(res.status, 200);
  });

  it("rejects other methods on /blobs with 405", async () => {
    const res = await request("POST", "/blobs");
    assert.equal(res.status, 405);
  });

  it("PUT with an empty body stores an empty blob (201)", async () => {
    const res = await request("PUT", "/blobs/0");
    assert.equal(res.status, 201);
    assert.deepEqual(JSON.parse(res.body), { key: "0", sha256: sha256(""), size: 0 });
  });

  it("PUT stores nested keys, overwrites, and GET /blobs reports metadata", async () => {
    let res = await request("PUT", "/blobs/docs/readme.txt", "first");
    assert.equal(res.status, 201);
    res = await request("PUT", "/blobs/docs/readme.txt", "hello world");
    assert.equal(res.status, 201);
    assert.deepEqual(JSON.parse(res.body), { key: "docs/readme.txt", sha256: sha256("hello world"), size: 11 });
    assert.equal(await readFile(join(dataDir, "blobs", "docs", "readme.txt"), "utf8"), "hello world");

    res = await request("PUT", "/blobs/caf%C3%A9%2Fmenu.txt", Buffer.from([0, 1, 2, 255]));
    assert.equal(res.status, 201);
    assert.equal(JSON.parse(res.body).key, "café/menu.txt");

    const byKey = new Map((await list()).map((b) => [b.key, b]));
    const readme = byKey.get("docs/readme.txt");
    assert.ok(readme);
    assert.equal(readme.size, 11);
    assert.equal(readme.sha256, sha256("hello world"));
    assert.match(readme.modified_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/);
    assert.equal(byKey.get("café/menu.txt")?.sha256, sha256(Buffer.from([0, 1, 2, 255])));
    assert.equal(byKey.get("0")?.size, 0);
  });

  it("PUT answers 400 for invalid keys and writes nothing outside the store", async () => {
    const before = await readdir(root);
    for (const path of [
      "/blobs/",
      "/blobs/../escape",
      "/blobs/a/../../escape",
      "/blobs/%2e%2e/escape",
      "/blobs/%2E%2E%2Fescape",
      "/blobs//etc/passwd",
      "/blobs/%2Fetc%2Fpasswd",
      "/blobs/a//b",
      "/blobs/a/",
      "/blobs/./a",
      "/blobs/%00",
      "/blobs/%",
      "/blobs/%zz",
      "/blobs/%FF",
      "/blobs/%ED%A0%80",
      `/blobs/${"a".repeat(256)}`,
    ]) {
      const res = await request("PUT", path, "x");
      assert.equal(res.status, 400, path);
    }
    assert.deepEqual(await readdir(root), before);
  });

  it("PUT answers 400 for raw non-UTF-8 bytes in the path", async () => {
    const status = await rawStatus("PUT", Buffer.concat([Buffer.from("/blobs/"), Buffer.from([0xff, 0xfe])]));
    assert.equal(status, 400);
  });

  it("PUT answers 400 when a key collides with an existing key's directory or file", async () => {
    assert.equal((await request("PUT", "/blobs/file", "x")).status, 201);
    assert.equal((await request("PUT", "/blobs/file/child", "x")).status, 400);
    assert.equal((await request("PUT", "/blobs/dir/child", "x")).status, 201);
    assert.equal((await request("PUT", "/blobs/dir", "x")).status, 400);
    // Failed uploads don't leave temporary files behind.
    assert.deepEqual(await readdir(join(dataDir, "tmp")), []);
  });

  it("answers within the contract for arbitrary keys and stays consistent", async () => {
    // Deterministic pseudo-random keys built from a mix of plain characters,
    // separators, dots, percent-escapes of arbitrary bytes and broken escapes.
    let seed = 12345;
    const rand = (n: number): number => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % n;
    };
    const pieces = ["a", "0", "Z", "-", "_", "~", ".", "..", "/", "%2F", "%2e", "%00", "%", "%g1", "%C3%A9", "%F0%9F%98%80"];
    for (let i = 0; i < 300; i++) {
      let key = "";
      const len = rand(8);
      for (let j = 0; j < len; j++) {
        key += rand(3) === 0 ? `%${rand(256).toString(16).padStart(2, "0")}` : pieces[rand(pieces.length)];
      }
      const res = await request("PUT", `/blobs/${key}`, `body ${i}`);
      assert.ok([201, 400].includes(res.status), `PUT /blobs/${key} -> ${res.status}`);
    }

    const blobs = await list();
    assert.ok(blobs.length > 0);
    for (const blob of blobs) {
      const content = await readFile(join(dataDir, "blobs", ...blob.key.split("/")));
      assert.equal(blob.size, content.length, blob.key);
      assert.equal(blob.sha256, sha256(content), blob.key);
    }
    assert.equal((await request("GET", "/healthz")).status, 200);
  });

  it("handles concurrent PUTs to the same and different keys", async () => {
    const bodies = Array.from({ length: 20 }, (_, i) => `payload-${i}-`.repeat(1000));
    const results = await Promise.all([
      ...bodies.map((b, i) => request("PUT", `/blobs/concurrent/${i}`, b)),
      ...bodies.map((b) => request("PUT", "/blobs/concurrent/shared", b)),
    ]);
    assert.ok(results.every((r) => r.status === 201));

    const byKey = new Map((await list()).map((b) => [b.key, b]));
    bodies.forEach((b, i) => assert.equal(byKey.get(`concurrent/${i}`)?.sha256, sha256(b)));
    const shared = await readFile(join(dataDir, "blobs", "concurrent", "shared"), "utf8");
    assert.ok(bodies.includes(shared));
    assert.equal(byKey.get("concurrent/shared")?.sha256, sha256(shared));
  });
});
