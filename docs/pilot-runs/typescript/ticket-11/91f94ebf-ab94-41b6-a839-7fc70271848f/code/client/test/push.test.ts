import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { push } from "../src/push";
import { TestServer } from "./testServer";

// Paths in this set raise EACCES from readFileSync, simulating a local file
// that can't be read. vi.spyOn can't redefine node:fs's readFileSync (its
// binding isn't configurable under vitest's module transform), so the
// module itself is mocked instead, delegating everything but the
// intercepted paths to the real implementation.
const unreadablePaths = vi.hoisted(() => new Set<string>());

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs")>();
  return {
    ...actual,
    readFileSync: (target: unknown, opts?: unknown) => {
      if (typeof target === "string" && unreadablePaths.has(target)) {
        throw Object.assign(new Error("EACCES: permission denied"), {
          code: "EACCES",
        });
      }
      return (actual.readFileSync as (...args: unknown[]) => unknown)(
        target,
        opts
      );
    },
  };
});

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
  unreadablePaths.clear();
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

  it("uploads the remaining files and reports the one that failed when the server errors on a single key", async () => {
    server.failKey("bad.txt", 500);
    fs.writeFileSync(path.join(dir, "bad.txt"), "will fail");
    fs.writeFileSync(path.join(dir, "good.txt"), "will succeed");

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual(["good.txt"]);
    expect(result.failed).toEqual([
      { key: "bad.txt", error: expect.stringContaining("500") },
    ]);
    expect(server.uploadedContent("good.txt")?.toString()).toBe(
      "will succeed"
    );
    expect(server.uploadedContent("bad.txt")).toBeUndefined();
  });

  it("uploads the remaining files and reports the one that failed when a local file can't be read", async () => {
    const badPath = path.join(dir, "unreadable.txt");
    fs.writeFileSync(badPath, "secret");
    fs.writeFileSync(path.join(dir, "good.txt"), "fine");
    unreadablePaths.add(badPath);

    const result = await push(dir, server.url);

    expect(result.uploaded).toEqual(["good.txt"]);
    expect(result.failed).toEqual([
      { key: "unreadable.txt", error: expect.stringContaining("EACCES") },
    ]);
  });
});
