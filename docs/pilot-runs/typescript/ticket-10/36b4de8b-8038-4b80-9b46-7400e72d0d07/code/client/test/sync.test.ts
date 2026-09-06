import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { sync } from "../src/sync";
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

/** Sets a file's mtime (and atime) to an exact timestamp for deterministic conflict tests. */
function setMtime(absPath: string, date: Date): void {
  fs.utimesSync(absPath, date, date);
}

describe("sync", () => {
  it("uploads a file that exists only locally", async () => {
    fs.writeFileSync(path.join(dir, "local-only.txt"), "brand new");

    const result = await sync(dir, server.url);

    expect(result.uploaded).toEqual(["local-only.txt"]);
    expect(result.downloaded).toEqual([]);
    expect(result.failed).toEqual([]);
    expect(server.uploadedContent("local-only.txt")?.toString()).toBe(
      "brand new"
    );
  });

  it("downloads a file that exists only on the server", async () => {
    server.seed("server-only.txt", Buffer.from("stays remote no more"));

    const result = await sync(dir, server.url);

    expect(result.downloaded).toEqual(["server-only.txt"]);
    expect(result.uploaded).toEqual([]);
    expect(
      fs.readFileSync(path.join(dir, "server-only.txt")).toString()
    ).toBe("stays remote no more");
  });

  it("leaves a file identical on both sides untouched", async () => {
    server.seed("same.txt", Buffer.from("same content"));
    fs.writeFileSync(path.join(dir, "same.txt"), "same content");

    const result = await sync(dir, server.url);

    expect(result.unchanged).toEqual(["same.txt"]);
    expect(result.uploaded).toEqual([]);
    expect(result.downloaded).toEqual([]);
  });

  it("keeps the local version when only the local copy changed since the last sync", async () => {
    server.seed("a.txt", Buffer.from("v1"));
    fs.writeFileSync(path.join(dir, "a.txt"), "v1");
    await sync(dir, server.url); // establishes the baseline

    fs.writeFileSync(path.join(dir, "a.txt"), "local v2");

    const result = await sync(dir, server.url);

    expect(result.uploaded).toEqual(["a.txt"]);
    expect(result.downloaded).toEqual([]);
    expect(server.uploadedContent("a.txt")?.toString()).toBe("local v2");
  });

  it("keeps the server version when only the server copy changed since the last sync", async () => {
    server.seed("a.txt", Buffer.from("v1"));
    fs.writeFileSync(path.join(dir, "a.txt"), "v1");
    await sync(dir, server.url); // establishes the baseline

    server.seed("a.txt", Buffer.from("server v2"));

    const result = await sync(dir, server.url);

    expect(result.downloaded).toEqual(["a.txt"]);
    expect(result.uploaded).toEqual([]);
    expect(fs.readFileSync(path.join(dir, "a.txt")).toString()).toBe(
      "server v2"
    );
  });

  it("resolves a real conflict in favor of the newer local version", async () => {
    const absPath = path.join(dir, "a.txt");
    const baseline = new Date("2026-01-01T00:00:00.000Z");
    server.seed("a.txt", Buffer.from("v1"), baseline.toISOString());
    fs.writeFileSync(absPath, "v1");
    setMtime(absPath, baseline);
    await sync(dir, server.url); // establishes the baseline

    const remoteTime = new Date("2026-01-02T00:00:00.000Z");
    const localTime = new Date("2026-01-03T00:00:00.000Z"); // newer

    server.seed("a.txt", Buffer.from("server v2"), remoteTime.toISOString());
    fs.writeFileSync(absPath, "local v2");
    setMtime(absPath, localTime);

    const result = await sync(dir, server.url);

    expect(result.uploaded).toEqual(["a.txt"]);
    expect(result.downloaded).toEqual([]);
    expect(server.uploadedContent("a.txt")?.toString()).toBe("local v2");
  });

  it("resolves a real conflict in favor of the newer server version", async () => {
    const absPath = path.join(dir, "a.txt");
    const baseline = new Date("2026-01-01T00:00:00.000Z");
    server.seed("a.txt", Buffer.from("v1"), baseline.toISOString());
    fs.writeFileSync(absPath, "v1");
    setMtime(absPath, baseline);
    await sync(dir, server.url); // establishes the baseline

    const localTime = new Date("2026-01-02T00:00:00.000Z");
    const remoteTime = new Date("2026-01-03T00:00:00.000Z"); // newer

    server.seed("a.txt", Buffer.from("server v2"), remoteTime.toISOString());
    fs.writeFileSync(absPath, "local v2");
    setMtime(absPath, localTime);

    const result = await sync(dir, server.url);

    expect(result.downloaded).toEqual(["a.txt"]);
    expect(result.uploaded).toEqual([]);
    expect(fs.readFileSync(absPath).toString()).toBe("server v2");
  });

  it("resolves a conflict with equal timestamps in favor of the local version", async () => {
    const absPath = path.join(dir, "a.txt");
    const baseline = new Date("2026-01-01T00:00:00.000Z");
    server.seed("a.txt", Buffer.from("v1"), baseline.toISOString());
    fs.writeFileSync(absPath, "v1");
    setMtime(absPath, baseline);
    await sync(dir, server.url); // establishes the baseline

    const tieTime = new Date("2026-01-02T00:00:00.000Z");

    server.seed("a.txt", Buffer.from("server v2"), tieTime.toISOString());
    fs.writeFileSync(absPath, "local v2");
    setMtime(absPath, tieTime);

    const result = await sync(dir, server.url);

    expect(result.uploaded).toEqual(["a.txt"]);
    expect(result.downloaded).toEqual([]);
    expect(server.uploadedContent("a.txt")?.toString()).toBe("local v2");
  });

  it("handles a mix of local-only, server-only and unchanged files in one pass", async () => {
    server.seed("unchanged.txt", Buffer.from("same"));
    fs.writeFileSync(path.join(dir, "unchanged.txt"), "same");
    fs.writeFileSync(path.join(dir, "local-only.txt"), "only here");
    server.seed("server-only.txt", Buffer.from("only there"));

    const result = await sync(dir, server.url);

    expect(result.uploaded).toEqual(["local-only.txt"]);
    expect(result.downloaded).toEqual(["server-only.txt"]);
    expect(result.unchanged).toEqual(["unchanged.txt"]);
  });

  it("creates missing subdirectories for a namespaced server-only key", async () => {
    server.seed("a/b/deep.txt", Buffer.from("deep"));

    const result = await sync(dir, server.url);

    expect(result.downloaded).toEqual(["a/b/deep.txt"]);
    expect(
      fs.readFileSync(path.join(dir, "a", "b", "deep.txt")).toString()
    ).toBe("deep");
  });

  it("does not sync its own manifest file as if it were user content", async () => {
    fs.writeFileSync(path.join(dir, "a.txt"), "hello");

    await sync(dir, server.url);
    const remoteAfter = server.uploadedContent(".syncbox/manifest.json");

    expect(remoteAfter).toBeUndefined();
    expect(fs.existsSync(path.join(dir, ".syncbox", "manifest.json"))).toBe(
      true
    );

    const second = await sync(dir, server.url);
    expect(second.uploaded).toEqual([]);
    expect(second.unchanged).toEqual(["a.txt"]);
  });

  it("does not re-transfer anything on a second run with no changes", async () => {
    server.seed("remote.txt", Buffer.from("r"));
    fs.writeFileSync(path.join(dir, "local.txt"), "l");

    await sync(dir, server.url);
    const second = await sync(dir, server.url);

    expect(second.uploaded).toEqual([]);
    expect(second.downloaded).toEqual([]);
    expect(second.unchanged.sort()).toEqual(["local.txt", "remote.txt"]);
  });

  it("rejects when the server is unreachable, without hanging", async () => {
    await server.stop();

    await expect(sync(dir, server.url)).rejects.toThrow();
  });
});
