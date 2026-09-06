import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { push } from "../src/push";
import { TestServer } from "./testServer";

let dir: string;
let server: TestServer;

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "syncbox-client-test-"));
  server = new TestServer();
  await server.start();
});

afterEach(async () => {
  fs.rmSync(dir, { recursive: true, force: true });
  await server.stop();
});

describe("push", () => {
  it("uploads every local file when the server is empty", async () => {
    fs.writeFileSync(path.join(dir, "a.txt"), "hello");
    fs.mkdirSync(path.join(dir, "docs"));
    fs.writeFileSync(path.join(dir, "docs", "readme.txt"), "world");

    const result = await push(dir, server.url);

    expect(result.uploaded.sort()).toEqual(["a.txt", "docs/readme.txt"]);
    expect(result.skipped).toEqual([]);
    expect(result.failed).toEqual([]);
    expect(server.uploadedContent("a.txt")?.toString()).toBe("hello");
    expect(server.uploadedContent("docs/readme.txt")?.toString()).toBe(
      "world"
    );
  });

  it("does not re-upload a file identical to the server's version", async () => {
    server.seed("a.txt", Buffer.from("hello"));
    fs.writeFileSync(path.join(dir, "a.txt"), "hello");

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual([]);
    expect(result.skipped).toEqual(["a.txt"]);
  });

  it("re-uploads a file whose content differs from the server's version", async () => {
    server.seed("a.txt", Buffer.from("old content"));
    fs.writeFileSync(path.join(dir, "a.txt"), "new content");

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual(["a.txt"]);
    expect(result.skipped).toEqual([]);
    expect(server.uploadedContent("a.txt")?.toString()).toBe("new content");
  });

  it("uploads missing files while leaving unchanged ones alone, in one pass", async () => {
    server.seed("unchanged.txt", Buffer.from("same"));
    fs.writeFileSync(path.join(dir, "unchanged.txt"), "same");
    fs.writeFileSync(path.join(dir, "new.txt"), "brand new");

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual(["new.txt"]);
    expect(result.skipped).toEqual(["unchanged.txt"]);
  });

  it("does not upload a file that only exists on the server", async () => {
    server.seed("server-only.txt", Buffer.from("stays on server"));

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual([]);
    expect(result.skipped).toEqual([]);
  });

  it("uploads binary content byte-for-byte", async () => {
    const content = crypto.randomBytes(1024);
    fs.writeFileSync(path.join(dir, "blob.bin"), content);

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual(["blob.bin"]);
    expect(server.uploadedContent("blob.bin")).toEqual(content);
  });

  it("uploads a file under a key with a space, matching the server's decoding", async () => {
    fs.writeFileSync(path.join(dir, "my notes.txt"), "note");

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual(["my notes.txt"]);
    expect(server.uploadedContent("my notes.txt")?.toString()).toBe("note");
  });

  it("rejects when the server is unreachable, without hanging", async () => {
    await server.stop();

    await expect(push(dir, server.url)).rejects.toThrow();
  });
});
