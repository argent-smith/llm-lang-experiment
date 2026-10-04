import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdir, mkdtemp, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, beforeEach, describe, it } from "node:test";

import { startServer, type RunningServer } from "../src/server.js";

interface BlobMeta {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
}

const sha256 = (data: string | Buffer): string => createHash("sha256").update(data).digest("hex");

describe("GET /blobs", () => {
  let root: string;
  let dataDir: string;
  let blobsDir: string;
  let running: RunningServer;

  const url = (path: string): string => `http://127.0.0.1:${running.port}${path}`;

  async function list(): Promise<BlobMeta[]> {
    const res = await fetch(url("/blobs"));
    assert.equal(res.status, 200);
    return (await res.json()) as BlobMeta[];
  }

  async function put(key: string, body: string | Buffer): Promise<void> {
    const res = await fetch(url(`/blobs/${key}`), { method: "PUT", body });
    assert.equal(res.status, 201, `PUT ${key}`);
    await res.arrayBuffer();
  }

  async function del(key: string): Promise<number> {
    const res = await fetch(url(`/blobs/${key}`), { method: "DELETE" });
    await res.arrayBuffer();
    return res.status;
  }

  /** What GET /blobs should report for a file in the store. */
  async function expectedMeta(key: string, content: string | Buffer): Promise<BlobMeta> {
    const st = await stat(join(blobsDir, ...key.split("/")));
    return { key, size: Buffer.byteLength(content), sha256: sha256(content), modified_at: st.mtime.toISOString() };
  }

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-list-"));
    dataDir = join(root, "data");
    blobsDir = join(dataDir, "blobs");
    running = await startServer({ dataDir, port: 0 }, { host: "127.0.0.1" });
  });

  beforeEach(async () => {
    await rm(dataDir, { recursive: true, force: true });
    await mkdir(dataDir);
  });

  after(async () => {
    await running.close();
    await rm(root, { recursive: true, force: true });
  });

  it("returns an empty JSON array for an empty store", async () => {
    const res = await fetch(url("/blobs"));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(await res.text(), "[]");
  });

  it("returns an empty array once every blob is deleted, and ignores empty directories", async () => {
    await put("a/b/c.txt", "x");
    assert.equal(await del("a/b/c.txt"), 204);
    await mkdir(join(blobsDir, "empty", "nested"), { recursive: true });
    assert.deepEqual(await list(), []);
  });

  it("lists every blob, including nested ones, with exact metadata sorted by key", async () => {
    const blobs: Record<string, string | Buffer> = {
      "top.txt": "top level",
      "docs/readme.txt": "hello world",
      "docs/guide/deep/nested/file.md": "# deep",
      "café/menu.txt": Buffer.from([0, 1, 2, 255]),
      "empty": "",
      "bin/large.bin": randomBytes(3 * 1024 * 1024 + 17),
    };
    for (const [key, content] of Object.entries(blobs)) {
      await put(encodeURIComponent(key).replaceAll("%2F", "/"), content);
    }

    const expected = await Promise.all(
      Object.keys(blobs)
        .sort()
        .map((key) => expectedMeta(key, blobs[key]!)),
    );
    const listed = await list();
    assert.deepEqual(listed, expected);
    for (const blob of listed) {
      assert.deepEqual(Object.keys(blob).sort(), ["key", "modified_at", "sha256", "size"]);
      assert.match(blob.sha256, /^[0-9a-f]{64}$/);
      assert.match(blob.modified_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    }
  });

  it("reports the new size, hash and time after an overwrite", async () => {
    await put("doc.txt", "first version, rather long");
    const old = new Date("2020-01-02T03:04:05.678Z");
    await utimes(join(blobsDir, "doc.txt"), old, old);
    assert.equal((await list())[0]?.modified_at, "2020-01-02T03:04:05.678Z");

    await put("doc.txt", "v2");
    const [blob] = await list();
    assert.deepEqual(blob, await expectedMeta("doc.txt", "v2"));
    assert.notEqual(blob?.modified_at, old.toISOString());
  });

  it("reports modified_at as the millisecond a client set with utimes()", async () => {
    await put("t", "t");
    for (const iso of ["1999-12-31T23:59:59.999Z", "2030-06-15T12:00:00.001Z", "1969-12-31T23:59:59.123Z"]) {
      const time = new Date(iso);
      await utimes(join(blobsDir, "t"), time, time);
      assert.equal((await list())[0]?.modified_at, iso);
      assert.equal((await stat(join(blobsDir, "t"))).mtime.toISOString(), iso);
    }
  });

  it("lists files placed in the store directly and notices when they change", async () => {
    await mkdir(join(blobsDir, "ext"), { recursive: true });
    const path = join(blobsDir, "ext", "file.txt");
    await writeFile(path, "aaaa");
    assert.deepEqual(await list(), [await expectedMeta("ext/file.txt", "aaaa")]);

    // Same size, rewritten in place: the hash must not come from a stale cache.
    await writeFile(path, "bbbb");
    const later = new Date(Date.now() + 5000);
    await utimes(path, later, later);
    assert.deepEqual(await list(), [await expectedMeta("ext/file.txt", "bbbb")]);

    await rm(path);
    assert.deepEqual(await list(), []);
  });

  it("skips files whose names no key can address", async () => {
    await put("ok.txt", "ok");
    await writeFile(Buffer.concat([Buffer.from(blobsDir + "/"), Buffer.from([0x66, 0xff, 0xfe])]), "latin1 junk");
    assert.deepEqual(
      (await list()).map((b) => b.key),
      ["ok.txt"],
    );
  });

  it("does not list uploads that are still in progress", async () => {
    await put("done.txt", "done");
    const content = randomBytes(64 * 1024);

    let finish!: () => void;
    const response = new Promise<number>((resolve, reject) => {
      const req = http.request(url("/blobs/pending.bin"), { method: "PUT" }, (res) => {
        res.resume();
        res.on("end", () => resolve(res.statusCode!));
      });
      req.on("error", reject);
      req.write(content.subarray(0, 1024));
      finish = () => req.end(content.subarray(1024));
    });

    // Wait until the server has started writing the upload.
    const tmpDir = join(dataDir, "tmp");
    for (let i = 0; ; i++) {
      const pending = await readdir(tmpDir).catch(() => []);
      if (pending.length > 0) break;
      assert.ok(i < 200, "upload never started");
      await new Promise((r) => setTimeout(r, 10));
    }
    assert.deepEqual(
      (await list()).map((b) => b.key),
      ["done.txt"],
    );

    finish();
    assert.equal(await response, 201);
    const byKey = new Map((await list()).map((b) => [b.key, b]));
    assert.equal(byKey.get("pending.bin")?.sha256, sha256(content));
    assert.equal(byKey.get("pending.bin")?.size, content.length);
  });

  it("answers HEAD with 200 and no body", async () => {
    await put("x", "x");
    const res = await fetch(url("/blobs"), { method: "HEAD" });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
    assert.equal(await res.text(), "");
  });

  it("stays consistent while PUTs and DELETEs reshape the tree", async () => {
    // `flip` keeps switching between being a blob and a directory of blobs.
    let active = true;
    const churn = (async () => {
      for (let i = 0; active; i++) {
        await put("flip/child", `child ${i}`);
        await del("flip/child");
        await put("flip", `file ${i}`);
        await del("flip");
      }
    })();
    const writers = Array.from({ length: 4 }, async (_, w) => {
      for (let i = 0; active; i++) {
        await put(`stable/${w}`, `writer ${w} round ${i}`);
      }
    });

    try {
      for (let round = 0; round < 50; round++) {
        for (const blob of await list()) {
          assert.ok(["flip", "flip/child"].includes(blob.key) || blob.key.startsWith("stable/"), blob.key);
          assert.match(blob.sha256, /^[0-9a-f]{64}$/);
          assert.ok(Number.isInteger(blob.size) && blob.size >= 0);
          assert.ok(!Number.isNaN(Date.parse(blob.modified_at)));
        }
      }
    } finally {
      active = false;
      await Promise.all([churn, ...writers]);
    }

    const listed = await list();
    assert.deepEqual(
      listed.map((b) => b.key),
      ["stable/0", "stable/1", "stable/2", "stable/3"],
    );
    for (const blob of listed) {
      const res = await fetch(url(`/blobs/${blob.key}`));
      const body = Buffer.from(await res.arrayBuffer());
      assert.equal(blob.sha256, sha256(body), blob.key);
      assert.equal(blob.size, body.length, blob.key);
    }
  });
});
