import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { pull } from "../src/pull";
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

describe("pull", () => {
  it("downloads every remote file when the local dir is empty", async () => {
    server.seed("a.txt", Buffer.from("hello"));
    server.seed("docs/readme.txt", Buffer.from("world"));

    const result = await pull(dir, server.url);

    expect(result.downloaded.sort()).toEqual(["a.txt", "docs/readme.txt"]);
    expect(result.skipped).toEqual([]);
    expect(result.failed).toEqual([]);
    expect(fs.readFileSync(path.join(dir, "a.txt")).toString()).toBe("hello");
    expect(
      fs.readFileSync(path.join(dir, "docs", "readme.txt")).toString()
    ).toBe("world");
  });

  it("does not re-download a file identical to the local version", async () => {
    server.seed("a.txt", Buffer.from("hello"));
    fs.writeFileSync(path.join(dir, "a.txt"), "hello");

    const result = await pull(dir, server.url);

    expect(result.downloaded).toEqual([]);
    expect(result.skipped).toEqual(["a.txt"]);
  });

  it("re-downloads a file whose content differs from the local version", async () => {
    server.seed("a.txt", Buffer.from("new content"));
    fs.writeFileSync(path.join(dir, "a.txt"), "old content");

    const result = await pull(dir, server.url);

    expect(result.downloaded).toEqual(["a.txt"]);
    expect(result.skipped).toEqual([]);
    expect(fs.readFileSync(path.join(dir, "a.txt")).toString()).toBe(
      "new content"
    );
  });

  it("downloads missing files while leaving unchanged ones alone, in one pass", async () => {
    server.seed("unchanged.txt", Buffer.from("same"));
    fs.writeFileSync(path.join(dir, "unchanged.txt"), "same");
    server.seed("new.txt", Buffer.from("brand new"));

    const result = await pull(dir, server.url);

    expect(result.downloaded).toEqual(["new.txt"]);
    expect(result.skipped).toEqual(["unchanged.txt"]);
  });

  it("does not delete a file that only exists locally", async () => {
    fs.writeFileSync(path.join(dir, "local-only.txt"), "stays local");

    const result = await pull(dir, server.url);

    expect(result.downloaded).toEqual([]);
    expect(result.skipped).toEqual([]);
    expect(fs.readFileSync(path.join(dir, "local-only.txt")).toString()).toBe(
      "stays local"
    );
  });

  it("downloads binary content byte-for-byte", async () => {
    const content = crypto.randomBytes(1024);
    server.seed("blob.bin", content);

    const result = await pull(dir, server.url);

    expect(result.downloaded).toEqual(["blob.bin"]);
    expect(fs.readFileSync(path.join(dir, "blob.bin"))).toEqual(content);
  });

  it("downloads a file under a key with a space, matching the server's decoding", async () => {
    server.seed("my notes.txt", Buffer.from("note"));

    const result = await pull(dir, server.url);

    expect(result.downloaded).toEqual(["my notes.txt"]);
    expect(
      fs.readFileSync(path.join(dir, "my notes.txt")).toString()
    ).toBe("note");
  });

  it("creates missing nested directories for a namespaced key", async () => {
    server.seed("a/b/c/deep.txt", Buffer.from("deep"));

    const result = await pull(dir, server.url);

    expect(result.downloaded).toEqual(["a/b/c/deep.txt"]);
    expect(
      fs.readFileSync(path.join(dir, "a", "b", "c", "deep.txt")).toString()
    ).toBe("deep");
  });

  it("rejects when the server is unreachable, without hanging", async () => {
    await server.stop();

    await expect(pull(dir, server.url)).rejects.toThrow();
  });
});
