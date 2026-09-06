import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import type { AddressInfo } from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import request from "supertest";
import { createApp } from "../src/app";
import { putBlob } from "../src/blobs";

let dataDir: string;

beforeEach(() => {
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "syncbox-test-"));
});

afterEach(() => {
  fs.rmSync(dataDir, { recursive: true, force: true });
});

/** Lists leftover files in the .syncbox-tmp staging directory, if any. */
function tmpDirEntries(): string[] {
  const tmpDir = path.join(dataDir, ".syncbox-tmp");
  try {
    return fs.readdirSync(tmpDir);
  } catch {
    return [];
  }
}

describe("concurrent PUT to the same key", () => {
  it("never produces a corrupted (mixed) file, only fully-old or fully-new content", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const key = "racey.bin";
    const size = 2_000_000;
    const concurrency = 8;

    // Each request's body is entirely filled with a single distinct byte
    // value, so any interleaving of writes would produce a buffer that
    // fails "every byte equals my value" for every single request.
    const buffers = Array.from({ length: concurrency }, (_, i) =>
      Buffer.alloc(size, i + 1)
    );

    const responses = await Promise.all(
      buffers.map((buf) =>
        request(app)
          .put(`/blobs/${key}`)
          .set("Content-Type", "application/octet-stream")
          .send(buf)
      )
    );

    for (const res of responses) {
      expect(res.status).toBe(201);
    }

    const finalContent = fs.readFileSync(path.join(dataDir, key));
    expect(finalContent.length).toBe(size);

    const matchesExactlyOneBuffer = buffers.some((buf) =>
      buf.equals(finalContent)
    );
    expect(matchesExactlyOneBuffer).toBe(true);

    // GET must agree with what's on disk — never a torn read.
    const getRes = await request(app).get(`/blobs/${key}`);
    expect(getRes.status).toBe(200);
    expect(Buffer.compare(getRes.body, finalContent)).toBe(0);
  });

  it("leaves no leftover temp files after the race settles", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const key = "racey2.bin";

    await Promise.all(
      Array.from({ length: 10 }, (_, i) =>
        request(app)
          .put(`/blobs/${key}`)
          .set("Content-Type", "application/octet-stream")
          .send(Buffer.alloc(1000, i))
      )
    );

    expect(tmpDirEntries()).toEqual([]);
  });
});

describe("concurrent PUT to different keys", () => {
  it("stores each key's own content without cross-contamination", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const keys = Array.from({ length: 12 }, (_, i) => `key-${i}.bin`);
    const buffers = keys.map((_, i) => Buffer.alloc(50_000, i + 1));

    const responses = await Promise.all(
      keys.map((key, i) =>
        request(app)
          .put(`/blobs/${key}`)
          .set("Content-Type", "application/octet-stream")
          .send(buffers[i])
      )
    );

    responses.forEach((res, i) => {
      expect(res.status).toBe(201);
      expect(res.body.size).toBe(buffers[i].length);
      expect(res.body.sha256).toBe(
        crypto.createHash("sha256").update(buffers[i]).digest("hex")
      );
    });

    keys.forEach((key, i) => {
      const stored = fs.readFileSync(path.join(dataDir, key));
      expect(Buffer.compare(stored, buffers[i])).toBe(0);
    });

    expect(tmpDirEntries()).toEqual([]);
  });

  it("does not let a slow write to one key delay or affect a GET on another", async () => {
    const app = createApp({ dataDir, port: 8080 });
    await request(app)
      .put("/blobs/existing.txt")
      .set("Content-Type", "application/octet-stream")
      .send(Buffer.from("already here"));

    const bigPut = request(app)
      .put("/blobs/big.bin")
      .set("Content-Type", "application/octet-stream")
      .send(Buffer.alloc(20_000_000, 7));

    const getRes = await request(app).get("/blobs/existing.txt");

    expect(getRes.status).toBe(200);
    expect(getRes.body.toString()).toBe("already here");

    const putRes = await bigPut;
    expect(putRes.status).toBe(201);
  });
});

describe("temp staging directory isolation", () => {
  const reservedUrls = [
    "/blobs/.syncbox-tmp",
    "/blobs/.syncbox-tmp/",
    "/blobs/.syncbox-tmp/somefile.tmp",
    "/blobs/.syncbox-tmp/nested/path.tmp",
  ];

  it.each(reservedUrls)("rejects PUT %s with 400", async (url) => {
    const app = createApp({ dataDir, port: 8080 });
    const res = await request(app)
      .put(url)
      .set("Content-Type", "application/octet-stream")
      .send(Buffer.from("x"));
    expect(res.status).toBe(400);
  });

  it.each(reservedUrls)("rejects GET %s with 400", async (url) => {
    const app = createApp({ dataDir, port: 8080 });
    const res = await request(app).get(url);
    expect(res.status).toBe(400);
  });

  it.each(reservedUrls)("rejects DELETE %s with 400", async (url) => {
    const app = createApp({ dataDir, port: 8080 });
    const res = await request(app).delete(url);
    expect(res.status).toBe(400);
  });

  it("stays unreachable even if a caller guesses an actual in-flight temp filename", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const tmpDir = path.join(dataDir, ".syncbox-tmp");
    fs.mkdirSync(tmpDir, { recursive: true });
    fs.writeFileSync(path.join(tmpDir, "guessed.tmp"), "leaked");

    const res = await request(app).get("/blobs/.syncbox-tmp/guessed.tmp");
    expect(res.status).toBe(400);

    const listRes = await request(app).get("/blobs");
    expect(listRes.body).toEqual([]);
  });
});

describe("cleanup on write failure", () => {
  // Real filesystem faults rather than mocks, so the test exercises the
  // actual try/finally cleanup path in putBlob end to end.

  it("leaves no temp file behind and does not touch the destination when rename fails", () => {
    // A file can never be renamed onto an existing non-empty directory
    // (EISDIR) — a deterministic, privilege-independent rename failure.
    const collisionDir = path.join(dataDir, "collision");
    fs.mkdirSync(collisionDir);
    fs.writeFileSync(path.join(collisionDir, "inner.txt"), "keep");

    expect(() => putBlob(dataDir, "collision", Buffer.from("new"))).toThrow();

    expect(fs.readFileSync(path.join(collisionDir, "inner.txt"), "utf8")).toBe(
      "keep"
    );
    expect(tmpDirEntries()).toEqual([]);
  });

  it("leaves no temp file behind and preserves prior content when the staging directory can't be created", () => {
    fs.writeFileSync(path.join(dataDir, "prior.txt"), "original");
    // Block .syncbox-tmp with a regular file so mkdirSync(tmpDir) fails.
    fs.writeFileSync(path.join(dataDir, ".syncbox-tmp"), "not a directory");

    expect(() =>
      putBlob(dataDir, "prior.txt", Buffer.from("new content"))
    ).toThrow();

    expect(fs.readFileSync(path.join(dataDir, "prior.txt"), "utf8")).toBe(
      "original"
    );
  });
});

describe("aborted connection during PUT", () => {
  it("leaves no temp file behind when the client disconnects mid-upload", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const server = app.listen(0);
    try {
      const port = (server.address() as AddressInfo).port;

      await new Promise<void>((resolve, reject) => {
        const req = http.request({
          host: "127.0.0.1",
          port,
          method: "PUT",
          path: "/blobs/aborted.bin",
          headers: {
            "Content-Type": "application/octet-stream",
            "Content-Length": "1000000",
          },
        });
        req.on("error", () => resolve());
        req.on("close", () => resolve());
        req.on("response", () => resolve());
        const timer = setTimeout(() => reject(new Error("timed out")), 5000);
        req.on("close", () => clearTimeout(timer));

        // Send far fewer bytes than promised, then destroy the socket once
        // the kernel confirms it was flushed — simulates a client that
        // disconnects mid-upload.
        req.write(Buffer.alloc(1000, 1), () => req.destroy());
      });

      // Give the server a moment to observe the aborted stream.
      await new Promise((r) => setTimeout(r, 100));

      expect(fs.existsSync(path.join(dataDir, "aborted.bin"))).toBe(false);
      expect(tmpDirEntries()).toEqual([]);
    } finally {
      server.close();
    }
  });
});
