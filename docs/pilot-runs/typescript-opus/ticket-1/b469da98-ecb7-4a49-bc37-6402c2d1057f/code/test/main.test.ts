import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm, stat } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

// Tests run from dist/test/, the entry point is compiled to dist/src/main.js.
const MAIN = fileURLToPath(new URL("../src/main.js", import.meta.url));

interface Result {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
}

function launch(args: string[], env: NodeJS.ProcessEnv = {}): { child: ChildProcess; result: Promise<Result> } {
  // Start from a clean environment so SYNCBOX_* from the outside can't leak in.
  const child = spawn(process.execPath, [MAIN, ...args], {
    env: { PATH: process.env.PATH, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout!.setEncoding("utf8").on("data", (c: string) => (stdout += c));
  child.stderr!.setEncoding("utf8").on("data", (c: string) => (stderr += c));
  const result = once(child, "exit").then(([code, signal]) => ({
    code: code as number | null,
    signal: signal as NodeJS.Signals | null,
    stdout,
    stderr,
  }));
  return { child, result };
}

async function freePort(): Promise<number> {
  const srv = net.createServer();
  srv.listen(0, "127.0.0.1");
  await once(srv, "listening");
  const { port } = srv.address() as net.AddressInfo;
  srv.close();
  await once(srv, "close");
  return port;
}

async function waitForHealthy(port: number, timeoutMs = 10_000): Promise<Response> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      return await fetch(`http://127.0.0.1:${port}/healthz`);
    } catch (err) {
      if (Date.now() > deadline) throw err;
      await new Promise((r) => setTimeout(r, 50));
    }
  }
}

describe("server process", () => {
  let root: string;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-main-"));
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("serves /healthz on the port given by flags and exits 0 on SIGTERM", async () => {
    const port = await freePort();
    const dataDir = join(root, "flags");
    const { child, result } = launch(["--data-dir", dataDir, "--port", String(port)]);
    try {
      const res = await waitForHealthy(port);
      assert.equal(res.status, 200);
      await res.body?.cancel();
      assert.ok((await stat(dataDir)).isDirectory());
    } finally {
      child.kill("SIGTERM");
    }
    const { code, stdout } = await result;
    assert.equal(code, 0);
    assert.match(stdout, new RegExp(`listening on port ${port}`));
  });

  it("is configurable through SYNCBOX_DATA_DIR / SYNCBOX_PORT and exits 0 on SIGINT", async () => {
    const port = await freePort();
    const dataDir = join(root, "env");
    const { child, result } = launch([], { SYNCBOX_DATA_DIR: dataDir, SYNCBOX_PORT: String(port) });
    try {
      const res = await waitForHealthy(port);
      assert.equal(res.status, 200);
      await res.body?.cancel();
      assert.ok((await stat(dataDir)).isDirectory());
    } finally {
      child.kill("SIGINT");
    }
    assert.equal((await result).code, 0);
  });

  it("exits 2 with a message when --data-dir is missing", async () => {
    const { code, stderr } = await launch(["--port", "9000"]).result;
    assert.equal(code, 2);
    assert.match(stderr, /--data-dir is required/);
    assert.match(stderr, /Usage:/);
  });

  it("exits 2 with a message on an invalid port", async () => {
    const { code, stderr } = await launch(["--data-dir", join(root, "x"), "--port", "http"]).result;
    assert.equal(code, 2);
    assert.match(stderr, /invalid port/);
  });

  it("exits 1 when the port is taken", async () => {
    const blocker = net.createServer();
    blocker.listen(0);
    await once(blocker, "listening");
    const { port } = blocker.address() as net.AddressInfo;
    try {
      const { code, stderr } = await launch(["--data-dir", join(root, "busy"), "--port", String(port)]).result;
      assert.equal(code, 1);
      assert.match(stderr, /failed to start: .*EADDRINUSE/);
    } finally {
      blocker.close();
    }
  });

  it("prints usage and exits 0 on --help", async () => {
    const { code, stdout } = await launch(["--help"]).result;
    assert.equal(code, 0);
    assert.match(stdout, /Usage: syncbox-server --data-dir <path>/);
  });
});
