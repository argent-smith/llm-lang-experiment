import * as fs from "node:fs";
import * as net from "node:net";
import type { AddressInfo } from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { runCli } from "../src/cli";
import { TestServer } from "./testServer";

let dir: string;
let server: TestServer;

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "syncbox-cli-test-"));
  server = new TestServer();
  await server.start();
});

afterEach(async () => {
  fs.rmSync(dir, { recursive: true, force: true });
  await server.stop();
  vi.restoreAllMocks();
});

function allStderr(spy: { mock: { calls: unknown[][] } }): string {
  return spy.mock.calls.flat().join(" ");
}

describe("runCli", () => {
  it("exits 0 and prints nothing to stderr on a clean push", async () => {
    fs.writeFileSync(path.join(dir, "a.txt"), "hello");
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = await runCli(
      ["push", dir, "--server", server.url],
      process.env
    );

    expect(code).toBe(0);
    expect(errorSpy).not.toHaveBeenCalled();
  });

  it("exits 0 on a clean status with no differences", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = await runCli(
      ["status", dir, "--server", server.url],
      process.env
    );

    expect(code).toBe(0);
    expect(errorSpy).not.toHaveBeenCalled();
  });

  it("reports a clear reason and a non-zero exit code when the server refuses the connection", async () => {
    await server.stop();
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = await runCli(
      ["push", dir, "--server", server.url],
      process.env
    );

    expect(code).not.toBe(0);
    expect(allStderr(errorSpy)).toMatch(/refused/i);
  });

  it(
    "reports a clear reason and a non-zero exit code, without hanging, " +
      "when the server accepts the connection but never responds",
    async () => {
      const sockets: net.Socket[] = [];
      const hung = net.createServer((socket) => {
        sockets.push(socket);
      });
      await new Promise<void>((resolve) => hung.listen(0, resolve));
      const port = (hung.address() as AddressInfo).port;
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const start = Date.now();
      const code = await runCli(
        ["status", dir, "--server", `http://127.0.0.1:${port}`],
        process.env
      );
      const elapsed = Date.now() - start;

      sockets.forEach((s) => s.destroy());
      await new Promise<void>((resolve) => hung.close(() => resolve()));

      expect(code).not.toBe(0);
      expect(elapsed).toBeLessThan(15_000);
      expect(allStderr(errorSpy)).toMatch(/timed out/i);
    },
    20_000
  );

  it("uploads the remaining files and exits non-zero when push fails on one key", async () => {
    server.failKey("bad.txt", 500);
    fs.writeFileSync(path.join(dir, "bad.txt"), "will fail");
    fs.writeFileSync(path.join(dir, "good.txt"), "will succeed");
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = await runCli(
      ["push", dir, "--server", server.url],
      process.env
    );

    expect(code).not.toBe(0);
    expect(server.uploadedContent("good.txt")?.toString()).toBe(
      "will succeed"
    );
    expect(allStderr(errorSpy)).toMatch(/bad\.txt/);
  });

  it("downloads the remaining files and exits non-zero when pull fails on one key", async () => {
    server.seed("good.txt", Buffer.from("ok"));
    server.seed("bad.txt", Buffer.from("nope"));
    server.failKey("bad.txt", 500);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = await runCli(
      ["pull", dir, "--server", server.url],
      process.env
    );

    expect(code).not.toBe(0);
    expect(fs.readFileSync(path.join(dir, "good.txt")).toString()).toBe("ok");
    expect(fs.existsSync(path.join(dir, "bad.txt"))).toBe(false);
    expect(allStderr(errorSpy)).toMatch(/bad\.txt/);
  });

  it("syncs the remaining files and exits non-zero when sync fails on one key", async () => {
    server.failKey("bad.txt", 500);
    fs.writeFileSync(path.join(dir, "bad.txt"), "will fail");
    fs.writeFileSync(path.join(dir, "good.txt"), "will succeed");
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = await runCli(
      ["sync", dir, "--server", server.url],
      process.env
    );

    expect(code).not.toBe(0);
    expect(server.uploadedContent("good.txt")?.toString()).toBe(
      "will succeed"
    );
    expect(allStderr(errorSpy)).toMatch(/bad\.txt/);
  });
});
