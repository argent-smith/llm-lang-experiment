import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { listRemoteBlobs } from "../src/httpClient";
import { status } from "../src/status";
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

describe("status", () => {
  it("reports no differences when local and server match", async () => {
    server.seed("a.txt", Buffer.from("hello"));
    fs.writeFileSync(path.join(dir, "a.txt"), "hello");

    const result = await status(dir, server.url);

    expect(result.toUpload).toEqual([]);
    expect(result.toDownload).toEqual([]);
    expect(result.unchanged).toEqual(["a.txt"]);
  });

  it("reports upload direction for a file that only exists locally", async () => {
    fs.writeFileSync(path.join(dir, "new.txt"), "brand new");

    const result = await status(dir, server.url);

    expect(result.toUpload).toEqual(["new.txt"]);
    expect(result.toDownload).toEqual([]);
    expect(result.unchanged).toEqual([]);
  });

  it("reports download direction for a file that only exists on the server", async () => {
    server.seed("server-only.txt", Buffer.from("stays on server"));

    const result = await status(dir, server.url);

    expect(result.toUpload).toEqual([]);
    expect(result.toDownload).toEqual(["server-only.txt"]);
    expect(result.unchanged).toEqual([]);
  });

  it("reports both directions for a file that diverged in content on both sides", async () => {
    server.seed("a.txt", Buffer.from("server content"));
    fs.writeFileSync(path.join(dir, "a.txt"), "local content");

    const result = await status(dir, server.url);

    expect(result.toUpload).toEqual(["a.txt"]);
    expect(result.toDownload).toEqual(["a.txt"]);
    expect(result.unchanged).toEqual([]);
  });

  it("handles a mix of unchanged, local-only, server-only and diverged files in one pass", async () => {
    server.seed("unchanged.txt", Buffer.from("same"));
    fs.writeFileSync(path.join(dir, "unchanged.txt"), "same");
    fs.writeFileSync(path.join(dir, "local-only.txt"), "only here");
    server.seed("server-only.txt", Buffer.from("only there"));
    server.seed("diverged.txt", Buffer.from("server version"));
    fs.writeFileSync(path.join(dir, "diverged.txt"), "local version");

    const result = await status(dir, server.url);

    expect(result.toUpload.sort()).toEqual(["diverged.txt", "local-only.txt"]);
    expect(result.toDownload.sort()).toEqual([
      "diverged.txt",
      "server-only.txt",
    ]);
    expect(result.unchanged).toEqual(["unchanged.txt"]);
  });

  it("does not modify the server or the local filesystem", async () => {
    server.seed("server-only.txt", Buffer.from("stays on server"));
    fs.writeFileSync(path.join(dir, "local-only.txt"), "stays local");

    await status(dir, server.url);

    const remoteAfter = await listRemoteBlobs(server.url);
    expect(remoteAfter.map((b) => b.key)).toEqual(["server-only.txt"]);
    expect(server.uploadedContent("server-only.txt")?.toString()).toBe(
      "stays on server"
    );

    expect(fs.readdirSync(dir).sort()).toEqual(["local-only.txt"]);
    expect(fs.readFileSync(path.join(dir, "local-only.txt")).toString()).toBe(
      "stays local"
    );
  });

  it("rejects when the server is unreachable, without hanging", async () => {
    await server.stop();

    await expect(status(dir, server.url)).rejects.toThrow();
  });

  it("reports the rest of the comparison and flags a local file that can't be read", async () => {
    const badPath = path.join(dir, "unreadable.txt");
    fs.writeFileSync(badPath, "secret");
    fs.writeFileSync(path.join(dir, "good.txt"), "brand new");
    unreadablePaths.add(badPath);

    const result = await status(dir, server.url);

    expect(result.toUpload).toEqual(["good.txt"]);
    expect(result.failed).toEqual([
      { key: "unreadable.txt", error: expect.stringContaining("EACCES") },
    ]);
  });
});
