import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import request from "supertest";
import { createApp } from "../src/app";

let dataDir: string;

beforeEach(() => {
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "syncbox-test-"));
});

afterEach(() => {
  fs.rmSync(dataDir, { recursive: true, force: true });
});

describe("GET /blobs", () => {
  it("returns 200 with an empty array when the store is empty", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const res = await request(app).get("/blobs");
    expect(res.status).toBe(200);
    expect(res.body).toEqual([]);
  });

  it("returns 200 with metadata for stored blobs", async () => {
    const app = createApp({ dataDir, port: 8080 });
    await request(app)
      .put("/blobs/docs/readme.txt")
      .set("Content-Type", "application/octet-stream")
      .send(Buffer.from("hello"));

    const res = await request(app).get("/blobs");
    expect(res.status).toBe(200);
    expect(res.body).toEqual([
      {
        key: "docs/readme.txt",
        size: 5,
        sha256: crypto.createHash("sha256").update("hello").digest("hex"),
        modified_at: expect.any(String),
      },
    ]);
  });
});

describe("PUT /blobs/{key}", () => {
  it("stores a blob and returns 201 with key/sha256/size", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const content = Buffer.from("hello world");

    const res = await request(app)
      .put("/blobs/greeting.txt")
      .set("Content-Type", "application/octet-stream")
      .send(content);

    expect(res.status).toBe(201);
    expect(res.body).toEqual({
      key: "greeting.txt",
      sha256: crypto.createHash("sha256").update(content).digest("hex"),
      size: content.length,
    });
    expect(fs.readFileSync(path.join(dataDir, "greeting.txt"))).toEqual(
      content
    );
  });

  it("supports nested keys, creating parent directories", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const res = await request(app)
      .put("/blobs/a/b/c.bin")
      .set("Content-Type", "application/octet-stream")
      .send(Buffer.from("x"));

    expect(res.status).toBe(201);
    expect(res.body.key).toBe("a/b/c.bin");
    expect(fs.readFileSync(path.join(dataDir, "a", "b", "c.bin"))).toEqual(
      Buffer.from("x")
    );
  });

  it("overwrites an existing key and returns 201 again", async () => {
    const app = createApp({ dataDir, port: 8080 });
    await request(app).put("/blobs/f.txt").send(Buffer.from("v1"));
    const res = await request(app).put("/blobs/f.txt").send(Buffer.from("v2"));

    expect(res.status).toBe(201);
    expect(fs.readFileSync(path.join(dataDir, "f.txt")).toString()).toBe(
      "v2"
    );
  });

  it("accepts an empty body as a zero-byte blob", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const res = await request(app)
      .put("/blobs/empty.bin")
      .set("Content-Type", "application/octet-stream");

    expect(res.status).toBe(201);
    expect(res.body.size).toBe(0);
  });

  it("never leaves the .syncbox-tmp staging directory visible in listings", async () => {
    const app = createApp({ dataDir, port: 8080 });
    await request(app).put("/blobs/f.txt").send(Buffer.from("v"));
    const res = await request(app).get("/blobs");
    expect(res.body.map((b: { key: string }) => b.key)).toEqual(["f.txt"]);
  });

  describe("rejects garbage/boundary keys with 400 (never 404, never 5xx)", () => {
    const cases: Record<string, string> = {
      "empty key (trailing slash, no key)": "/blobs/",
      "single dot-dot segment": "/blobs/..",
      "leading dot-dot traversal": "/blobs/../secret",
      "embedded dot-dot traversal": "/blobs/a/../../secret",
      "absolute path via double slash": "/blobs//etc/passwd",
      "encoded absolute path": "/blobs/%2Fetc%2Fpasswd",
      "encoded dot-dot traversal": "/blobs/..%2F..%2Fetc%2Fpasswd",
      "trailing slash after a real segment": "/blobs/dir/",
      "double slash mid-key": "/blobs/a//b",
      "embedded NUL byte": "/blobs/a%00b",
      "malformed percent-encoding": "/blobs/%",
      "invalid percent-encoding continuation": "/blobs/%zz",
      "lone surrogate byte sequence": "/blobs/%ED%A0%80",
      "segment longer than filesystem limit": `/blobs/${"a".repeat(300)}`,
    };

    for (const [name, url] of Object.entries(cases)) {
      it(name, async () => {
        const app = createApp({ dataDir, port: 8080 });
        const res = await request(app)
          .put(url)
          .set("Content-Type", "application/octet-stream")
          .send(Buffer.from("payload"));

        expect(res.status).toBe(400);
      });
    }
  });

  it("accepts a key containing a valid non-ASCII segment", async () => {
    const app = createApp({ dataDir, port: 8080 });
    const res = await request(app)
      .put("/blobs/" + encodeURIComponent("café.txt"))
      .set("Content-Type", "application/octet-stream")
      .send(Buffer.from("x"));

    expect(res.status).toBe(201);
    expect(res.body.key).toBe("café.txt");
  });
});
