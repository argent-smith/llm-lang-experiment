import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdir, mkdtemp, open, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough, Readable } from "node:stream";
import { after, afterEach, before, describe, it } from "node:test";

import { BlobStore } from "../src/blobs.js";
import { startServer, type RunningServer } from "../src/server.js";

const sha256 = (data: string | Buffer): string => createHash("sha256").update(data).digest("hex");

const delay = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Polls `check` until it returns true, failing after `timeoutMs`. */
async function waitFor(what: string, check: () => Promise<boolean>, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await check())) {
    assert.ok(Date.now() < deadline, `timed out waiting for ${what}`);
    await delay(5);
  }
}

/** Names of the uploads currently in the store's temporary directory. */
async function pendingUploads(dataDir: string): Promise<string[]> {
  return readdir(join(dataDir, "tmp")).catch(() => []);
}

/** Waits until an upload has written at least `bytes` bytes to its temporary file. */
async function waitForUpload(dataDir: string, bytes: number): Promise<string> {
  let path = "";
  await waitFor("the upload to reach the server's disk", async () => {
    for (const name of await pendingUploads(dataDir)) {
      const size = await stat(join(dataDir, "tmp", name)).then((s) => s.size, () => -1);
      if (size >= bytes) {
        path = join(dataDir, "tmp", name);
        return true;
      }
    }
    return false;
  });
  return path;
}

describe("BlobStore writes atomically", () => {
  let root: string;
  let dataDir: string;
  let store: BlobStore;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-atomic-"));
    dataDir = join(root, "data");
    store = new BlobStore(dataDir);
    await store.init();
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  afterEach(async () => {
    assert.deepEqual(await pendingUploads(dataDir), [], "temporary files left behind");
  });

  it("replaces the stored file with a new one instead of writing into it", async () => {
    await store.put("doc", Readable.from([Buffer.from("old version")]));
    const target = join(dataDir, "blobs", "doc");
    const before = await stat(target);
    const reader = await open(target, "r");
    try {
      await store.put("doc", Readable.from([Buffer.from("new, longer version")]));
      // A reader that opened the old file keeps reading it, untouched.
      assert.equal((await reader.readFile()).toString(), "old version");
    } finally {
      await reader.close();
    }
    assert.notEqual((await stat(target)).ino, before.ino);
    assert.equal(await readFile(target, "utf8"), "new, longer version");
  });

  it("keeps the previous version when the body fails midway", async () => {
    await store.put("kept", Readable.from([Buffer.from("intact")]));
    const failing = (): Readable =>
      Readable.from(
        (async function* () {
          yield Buffer.from("partial ");
          throw new Error("connection lost");
        })(),
      );
    await assert.rejects(store.put("kept", failing()), /connection lost/);
    await assert.rejects(store.put("never/stored", failing()), /connection lost/);
    assert.equal(await readFile(join(dataDir, "blobs", "kept"), "utf8"), "intact");
    assert.deepEqual(
      (await store.list()).map((b) => b.key),
      ["doc", "kept"],
    );
  });

  it("keeps the body out of the key's path until it is complete", async () => {
    await store.put("slow", Readable.from([Buffer.from("v1")]));
    const body = new PassThrough();
    const result = store.put("slow", body);
    body.write(Buffer.alloc(4096, "x"));
    const tmpFile = await waitForUpload(dataDir, 4096);

    // The temporary file shares the target's file system, so the final rename
    // swaps it in rather than copying it across.
    assert.equal((await stat(tmpFile)).dev, (await stat(join(dataDir, "blobs"))).dev);
    assert.equal(await readFile(join(dataDir, "blobs", "slow"), "utf8"), "v1");
    assert.ok(!(await store.list()).some((b) => b.size === 4096));

    body.end(Buffer.alloc(4096, "y"));
    const put = await result;
    assert.equal(put.size, 8192);
    assert.equal(put.sha256, sha256(await readFile(join(dataDir, "blobs", "slow"))));
  });

  it("counts and stores string chunks as UTF-8 bytes", async () => {
    const put = await store.put("text", Readable.from(["café ", "☕"]));
    const stored = await readFile(join(dataDir, "blobs", "text"));
    assert.equal(stored.toString("utf8"), "café ☕");
    assert.deepEqual(put, { key: "text", sha256: sha256(stored), size: stored.length });
  });

  it("init() clears uploads left behind by an interrupted run", async () => {
    await writeFile(join(dataDir, "tmp", "stale-upload"), "half a file");
    await mkdir(join(dataDir, "tmp", "stale-dir"));
    await writeFile(join(dataDir, "tmp", "stale-dir", "x"), "x");
    const blobsBefore = await store.list();
    await new BlobStore(dataDir).init();
    assert.deepEqual(await pendingUploads(dataDir), []);
    assert.deepEqual(await store.list(), blobsBefore);
  });
});

describe("concurrent PUTs over HTTP", () => {
  let root: string;
  let dataDir: string;
  let running: RunningServer;

  function request(method: string, path: string, body?: Buffer | string): Promise<{ status: number; bytes: Buffer }> {
    return new Promise((resolve, reject) => {
      const req = http.request({ host: "127.0.0.1", port: running.port, method, path }, (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () => resolve({ status: res.statusCode!, bytes: Buffer.concat(chunks) }));
        res.on("error", reject);
      });
      req.on("error", reject);
      req.end(body);
    });
  }

  async function list(): Promise<Array<{ key: string; size: number; sha256: string }>> {
    const res = await request("GET", "/blobs");
    assert.equal(res.status, 200);
    return JSON.parse(res.bytes.toString("utf8"));
  }

  /** Starts a PUT that sends `first` and then waits to be finished or aborted. */
  function startUpload(path: string, first: Buffer, totalLength: number) {
    const req = http.request({
      host: "127.0.0.1",
      port: running.port,
      method: "PUT",
      path,
      headers: { "Content-Length": totalLength },
    });
    const response = new Promise<number>((resolve, reject) => {
      req.on("response", (res) => {
        res.resume();
        res.on("end", () => resolve(res.statusCode!));
      });
      req.on("error", reject);
    });
    req.write(first);
    return {
      response,
      finish: (rest: Buffer) => req.end(rest),
      abort: () => {
        response.catch(() => {});
        req.destroy();
      },
    };
  }

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-atomic-http-"));
    dataDir = join(root, "data");
    running = await startServer({ dataDir, port: 0 }, { host: "127.0.0.1" });
  });

  after(async () => {
    await running.close();
    await rm(root, { recursive: true, force: true });
  });

  afterEach(async () => {
    assert.deepEqual(await pendingUploads(dataDir), [], "temporary files left behind");
  });

  it("serves the previous version in full while an overwrite is being uploaded", async () => {
    const v1 = randomBytes(100_000);
    const v2 = randomBytes(300_000);
    assert.equal((await request("PUT", "/blobs/report.bin", v1)).status, 201);

    const upload = startUpload("/blobs/report.bin", v2.subarray(0, 150_000), v2.length);
    await waitForUpload(dataDir, 150_000);

    const during = await request("GET", "/blobs/report.bin");
    assert.equal(during.status, 200);
    assert.ok(during.bytes.equals(v1));
    const listed = (await list()).find((b) => b.key === "report.bin");
    assert.deepEqual([listed?.size, listed?.sha256], [v1.length, sha256(v1)]);

    upload.finish(v2.subarray(150_000));
    assert.equal(await upload.response, 201);
    assert.ok((await request("GET", "/blobs/report.bin")).bytes.equals(v2));
  });

  it("never exposes a mixed or partial file to readers during concurrent PUTs to one key", async () => {
    const versions = Array.from({ length: 6 }, (_, i) => randomBytes(256 * 1024 + i * 4099));
    const known = new Map(versions.map((v) => [sha256(v), v.length]));
    assert.equal((await request("PUT", "/blobs/hot/key", versions[0]!)).status, 201);

    let writing = true;
    const writers = versions.map(async (body) => {
      for (let round = 0; round < 8; round++) {
        assert.equal((await request("PUT", "/blobs/hot/key", body)).status, 201);
      }
    });
    const readers = Array.from({ length: 4 }, async (_, r) => {
      let reads = 0;
      while (writing || reads === 0) {
        if (r === 0) {
          const blob = (await list()).find((b) => b.key === "hot/key");
          assert.equal(known.get(blob?.sha256 ?? ""), blob?.size, "listed metadata of an unknown version");
        } else {
          const res = await request("GET", "/blobs/hot/key");
          assert.equal(res.status, 200);
          assert.ok(known.has(sha256(res.bytes)), `GET returned ${res.bytes.length} bytes matching no version`);
        }
        reads++;
      }
    });

    try {
      await Promise.all(writers);
    } finally {
      writing = false;
      await Promise.all(readers);
    }
    const final = await request("GET", "/blobs/hot/key");
    assert.ok(known.has(sha256(final.bytes)));
  });

  it("lets a download started before an overwrite finish with the old content", async () => {
    const v1 = randomBytes(8 * 1024 * 1024);
    const v2 = randomBytes(1024);
    assert.equal((await request("PUT", "/blobs/big.bin", v1)).status, 201);

    const download = new Promise<Buffer>((resolve, reject) => {
      http
        .get({ host: "127.0.0.1", port: running.port, path: "/blobs/big.bin" }, (res) => {
          const chunks: Buffer[] = [];
          res.once("data", (c: Buffer) => {
            chunks.push(c);
            // Stall the download until the overwrite has gone through.
            res.pause();
            request("PUT", "/blobs/big.bin", v2)
              .then((put) => {
                assert.equal(put.status, 201);
                res.on("data", (more: Buffer) => chunks.push(more));
                res.resume();
              })
              .catch(reject);
          });
          res.on("end", () => resolve(Buffer.concat(chunks)));
          res.on("error", reject);
        })
        .on("error", reject);
    });
    assert.ok((await download).equals(v1));
    assert.ok((await request("GET", "/blobs/big.bin")).bytes.equals(v2));
  });

  it("stores concurrent PUTs to different keys without mixing them up", async () => {
    const bodies = Array.from({ length: 32 }, () => randomBytes(64 * 1024 + Math.floor(Math.random() * 64 * 1024)));
    const keys = bodies.map((_, i) => `parallel/${i % 4}/${i}.bin`);
    const results = await Promise.all(bodies.map((b, i) => request("PUT", `/blobs/${keys[i]}`, b)));
    for (const [i, res] of results.entries()) {
      assert.equal(res.status, 201);
      assert.deepEqual(JSON.parse(res.bytes.toString("utf8")), { key: keys[i], sha256: sha256(bodies[i]!), size: bodies[i]!.length });
    }

    const reads = await Promise.all(keys.map((k) => request("GET", `/blobs/${k}`)));
    reads.forEach((res, i) => assert.ok(res.bytes.equals(bodies[i]!), keys[i]));
    const byKey = new Map((await list()).map((b) => [b.key, b]));
    keys.forEach((k, i) => assert.equal(byKey.get(k)?.sha256, sha256(bodies[i]!), k));
  });

  it("removes the temporary file when the client disconnects mid-upload", async () => {
    assert.equal((await request("PUT", "/blobs/aborted/existing", "survives")).status, 201);

    for (const key of ["aborted/existing", "aborted/new"]) {
      const upload = startUpload(`/blobs/${key}`, randomBytes(64 * 1024), 1024 * 1024);
      await waitForUpload(dataDir, 64 * 1024);
      upload.abort();
      await waitFor("the partial upload to be removed", async () => (await pendingUploads(dataDir)).length === 0);
    }

    assert.equal((await request("GET", "/blobs/aborted/existing")).bytes.toString(), "survives");
    assert.equal((await request("GET", "/blobs/aborted/new")).status, 404);
    assert.deepEqual(
      (await list()).filter((b) => b.key.startsWith("aborted/")).map((b) => b.key),
      ["aborted/existing"],
    );
    assert.equal((await request("GET", "/healthz")).status, 200);
  });

  it("removes the temporary file when an uploaded body can't be stored under its key", async () => {
    assert.equal((await request("PUT", "/blobs/taken", "a file")).status, 201);
    assert.equal((await request("PUT", "/blobs/taken/child", randomBytes(128 * 1024))).status, 400);
    assert.equal((await request("GET", "/blobs/taken")).bytes.toString(), "a file");
  });

  it("does not serve temporary files under any key", async () => {
    const upload = startUpload("/blobs/hidden.bin", Buffer.alloc(4096, 1), 8192);
    const tmpFile = await waitForUpload(dataDir, 4096);
    const name = tmpFile.slice(tmpFile.lastIndexOf("/") + 1);

    for (const path of [`/blobs/${name}`, `/blobs/tmp/${name}`, `/blobs/..%2Ftmp%2F${name}`, `/blobs/../tmp/${name}`]) {
      assert.ok([400, 404].includes((await request("GET", path)).status), path);
    }
    assert.equal((await request("GET", "/blobs/hidden.bin")).status, 404);
    assert.ok(!(await list()).some((b) => b.key.includes(name) || b.key === "hidden.bin"));

    upload.finish(Buffer.alloc(4096, 2));
    assert.equal(await upload.response, 201);
    assert.equal((await request("GET", "/blobs/hidden.bin")).bytes.length, 8192);
  });
});

describe("startServer", () => {
  it("clears uploads left over from a previous run and does not list them", async () => {
    const root = await mkdtemp(join(tmpdir(), "syncbox-atomic-start-"));
    const dataDir = join(root, "data");
    await mkdir(join(dataDir, "tmp"), { recursive: true });
    await mkdir(join(dataDir, "blobs"), { recursive: true });
    await writeFile(join(dataDir, "tmp", "0b7d6f1e-crashed-upload"), "partial");
    await writeFile(join(dataDir, "blobs", "kept.txt"), "kept");

    const running = await startServer({ dataDir, port: 0 }, { host: "127.0.0.1" });
    try {
      assert.deepEqual(await pendingUploads(dataDir), []);
      const res = await fetch(`http://127.0.0.1:${running.port}/blobs`);
      assert.deepEqual(
        ((await res.json()) as Array<{ key: string }>).map((b) => b.key),
        ["kept.txt"],
      );
    } finally {
      await running.close();
      await rm(root, { recursive: true, force: true });
    }
  });
});
