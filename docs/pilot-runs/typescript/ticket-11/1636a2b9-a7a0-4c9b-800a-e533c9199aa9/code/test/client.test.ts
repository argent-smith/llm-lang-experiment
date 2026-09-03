import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import type { IncomingMessage } from "node:http";
import { test } from "node:test";
import { createApp } from "../src/server.js";
import { getBlob, putBlob } from "../src/storage.js";
import { runClient } from "../src/client.js";

/** Binds an ephemeral port and immediately frees it, so connecting to it is refused for real. */
async function unusedPort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, resolve));
  const { port } = probe.address() as AddressInfo;
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return port;
}

/**
 * A real server (backed by the real storage) that answers every request
 * normally except the ones `shouldFail` flags, which get a bare 500 - lets a
 * test force one specific request to fail while the rest succeed for real.
 */
async function withFlakyServer(
  shouldFail: (req: IncomingMessage) => boolean,
  fn: (baseUrl: string, dataDir: string) => Promise<void>,
): Promise<void> {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-server-"));
  const app = createApp(dataDir);
  const server = createServer((req, res) => {
    if (shouldFail(req)) {
      res.writeHead(500);
      res.end();
      return;
    }
    app(req, res);
  });
  server.listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    await fn(`http://127.0.0.1:${port}`, dataDir);
  } finally {
    server.close();
    await rm(dataDir, { recursive: true, force: true });
  }
}

/** A server that accepts the TCP connection but never sends a response. */
async function withHangingServer(
  fn: (baseUrl: string) => Promise<void>,
): Promise<void> {
  const server = createServer(() => {
    // Intentionally never responds.
  });
  server.listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    await fn(`http://127.0.0.1:${port}`);
  } finally {
    server.close();
    server.closeAllConnections();
  }
}

async function captureConsole(
  fn: () => Promise<number>,
): Promise<{ code: number; stdout: string; stderr: string }> {
  const originalLog = console.log;
  const originalError = console.error;
  let stdout = "";
  let stderr = "";
  console.log = (...args: unknown[]) => {
    stdout += `${args.join(" ")}\n`;
  };
  console.error = (...args: unknown[]) => {
    stderr += `${args.join(" ")}\n`;
  };
  try {
    const code = await fn();
    return { code, stdout, stderr };
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
}

test("runClient reports a config error and exits non-zero", async () => {
  const { code, stderr } = await captureConsole(() =>
    runClient(["push", "/tmp/x"], {}),
  );
  assert.equal(code, 1);
  assert.match(stderr, /--server is required/);
});

test("runClient sync transfers files both ways against a real server and exits 0", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-server-"));
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  const server = createApp(dataDir).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    const baseUrl = `http://127.0.0.1:${port}`;
    await writeFile(join(dataDir, "remote-only.txt"), "on server");
    await writeFile(join(localDir, "local-only.txt"), "on disk");

    const { code, stdout } = await captureConsole(() =>
      runClient(["sync", localDir, "--server", baseUrl], {}),
    );

    assert.equal(code, 0);
    assert.match(stdout, /uploaded local-only\.txt/);
    assert.match(stdout, /downloaded remote-only\.txt/);
    assert.match(stdout, /1 uploaded, 1 downloaded, 0 unchanged/);
    assert.equal(
      await readFile(join(localDir, "remote-only.txt"), "utf8"),
      "on server",
    );
  } finally {
    server.close();
    await rm(dataDir, { recursive: true, force: true });
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient sync reports a clear error and exits non-zero when the server is unreachable", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    const port = await unusedPort();
    const start = Date.now();
    const { code, stderr } = await captureConsole(() =>
      runClient(["sync", localDir, "--server", `http://127.0.0.1:${port}`], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: sync failed/);
    assert.match(stderr, /connection refused/);
    assert.ok(Date.now() - start < 5_000, "must not hang when connection is refused");
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient sync reports a clear error and exits non-zero when the server never responds", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await withHangingServer(async (baseUrl) => {
      const start = Date.now();
      const { code, stderr } = await captureConsole(() =>
        runClient(["sync", localDir, "--server", baseUrl], {}, { timeoutMs: 200 }),
      );

      assert.equal(code, 1);
      assert.match(stderr, /syncbox: sync failed/);
      assert.match(stderr, /timed out/);
      assert.ok(Date.now() - start < 5_000, "must not hang waiting for a response");
    });
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient sync reports the failed file and exits non-zero when one of several files fails to sync", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await writeFile(join(localDir, "good.txt"), "uploads fine");
    await writeFile(join(localDir, "bad.txt"), "upload fails");

    await withFlakyServer(
      (req) => req.method === "PUT" && req.url === "/blobs/bad.txt",
      async (baseUrl, dataDir) => {
        const { code, stdout, stderr } = await captureConsole(() =>
          runClient(["sync", localDir, "--server", baseUrl], {}),
        );

        assert.equal(code, 1);
        assert.match(stdout, /uploaded good\.txt/);
        assert.match(stderr, /bad\.txt/);
        assert.match(stderr, /1 file\(s\) failed/);
        assert.equal(
          (await getBlob(dataDir, "good.txt"))?.toString("utf8"),
          "uploads fine",
        );
        assert.equal(await getBlob(dataDir, "bad.txt"), undefined);
      },
    );
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient push uploads local files to a real server and exits 0", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-server-"));
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  const server = createApp(dataDir).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    await writeFile(join(localDir, "file.txt"), "content");

    const { code, stdout } = await captureConsole(() =>
      runClient(
        ["push", localDir, "--server", `http://127.0.0.1:${port}`],
        {},
      ),
    );

    assert.equal(code, 0);
    assert.match(stdout, /uploaded file\.txt/);
    assert.match(stdout, /1 uploaded, 0 unchanged/);
  } finally {
    server.close();
    await rm(dataDir, { recursive: true, force: true });
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient push reports a clear error and exits non-zero when the server is unreachable", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await writeFile(join(localDir, "file.txt"), "content");

    const port = await unusedPort();
    const start = Date.now();
    const { code, stderr } = await captureConsole(() =>
      runClient(["push", localDir, "--server", `http://127.0.0.1:${port}`], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: push failed/);
    assert.match(stderr, /connection refused/);
    assert.ok(Date.now() - start < 5_000, "must not hang when connection is refused");
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient push reports a clear error and exits non-zero when the server never responds", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await writeFile(join(localDir, "file.txt"), "content");

    await withHangingServer(async (baseUrl) => {
      const start = Date.now();
      const { code, stderr } = await captureConsole(() =>
        runClient(["push", localDir, "--server", baseUrl], {}, { timeoutMs: 200 }),
      );

      assert.equal(code, 1);
      assert.match(stderr, /syncbox: push failed/);
      assert.match(stderr, /timed out/);
      assert.ok(Date.now() - start < 5_000, "must not hang waiting for a response");
    });
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient push reports the failed file and exits non-zero when one of several files fails to upload", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await writeFile(join(localDir, "good.txt"), "uploads fine");
    await writeFile(join(localDir, "bad.txt"), "upload fails");

    await withFlakyServer(
      (req) => req.method === "PUT" && req.url === "/blobs/bad.txt",
      async (baseUrl, dataDir) => {
        const { code, stdout, stderr } = await captureConsole(() =>
          runClient(["push", localDir, "--server", baseUrl], {}),
        );

        assert.equal(code, 1);
        assert.match(stdout, /uploaded good\.txt/);
        assert.match(stderr, /bad\.txt/);
        assert.match(stderr, /1 file\(s\) failed/);
        assert.equal(
          (await getBlob(dataDir, "good.txt"))?.toString("utf8"),
          "uploads fine",
        );
        assert.equal(await getBlob(dataDir, "bad.txt"), undefined);
      },
    );
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient pull downloads server files to disk and exits 0", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-server-"));
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  const server = createApp(dataDir).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    const baseUrl = `http://127.0.0.1:${port}`;
    await writeFile(join(dataDir, "file.txt"), "content");

    const { code, stdout } = await captureConsole(() =>
      runClient(["pull", localDir, "--server", baseUrl], {}),
    );

    assert.equal(code, 0);
    assert.match(stdout, /downloaded file\.txt/);
    assert.match(stdout, /1 downloaded, 0 unchanged/);
    assert.equal(
      await readFile(join(localDir, "file.txt"), "utf8"),
      "content",
    );
  } finally {
    server.close();
    await rm(dataDir, { recursive: true, force: true });
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient pull reports a clear error and exits non-zero when the server is unreachable", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    const port = await unusedPort();
    const start = Date.now();
    const { code, stderr } = await captureConsole(() =>
      runClient(["pull", localDir, "--server", `http://127.0.0.1:${port}`], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: pull failed/);
    assert.match(stderr, /connection refused/);
    assert.ok(Date.now() - start < 5_000, "must not hang when connection is refused");
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient pull reports a clear error and exits non-zero when the server never responds", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await withHangingServer(async (baseUrl) => {
      const start = Date.now();
      const { code, stderr } = await captureConsole(() =>
        runClient(["pull", localDir, "--server", baseUrl], {}, { timeoutMs: 200 }),
      );

      assert.equal(code, 1);
      assert.match(stderr, /syncbox: pull failed/);
      assert.match(stderr, /timed out/);
      assert.ok(Date.now() - start < 5_000, "must not hang waiting for a response");
    });
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient pull reports the failed file and exits non-zero when one of several files fails to download", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await withFlakyServer(
      (req) => req.method === "GET" && req.url === "/blobs/bad.txt",
      async (baseUrl, dataDir) => {
        await putBlob(dataDir, "good.txt", Buffer.from("downloads fine"));
        await putBlob(dataDir, "bad.txt", Buffer.from("download fails"));

        const { code, stdout, stderr } = await captureConsole(() =>
          runClient(["pull", localDir, "--server", baseUrl], {}),
        );

        assert.equal(code, 1);
        assert.match(stdout, /downloaded good\.txt/);
        assert.match(stderr, /bad\.txt/);
        assert.match(stderr, /1 file\(s\) failed/);
        assert.equal(
          await readFile(join(localDir, "good.txt"), "utf8"),
          "downloads fine",
        );
        await assert.rejects(() => readFile(join(localDir, "bad.txt"), "utf8"));
      },
    );
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient status reports the diff against a real server and exits 0 without changing either side", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-server-"));
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  const server = createApp(dataDir).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    const baseUrl = `http://127.0.0.1:${port}`;
    await writeFile(join(dataDir, "remote-only.txt"), "on server");
    await writeFile(join(localDir, "local-only.txt"), "on disk");

    const { code, stdout } = await captureConsole(() =>
      runClient(["status", localDir, "--server", baseUrl], {}),
    );

    assert.equal(code, 0);
    assert.match(stdout, /would upload {3}local-only\.txt/);
    assert.match(stdout, /would download remote-only\.txt/);
    assert.match(stdout, /1 to upload, 1 to download, 0 unchanged/);

    // Read-only: neither side was touched by the dry run.
    const remoteEntries = (await readdir(dataDir)).sort();
    assert.deepEqual(remoteEntries, ["remote-only.txt"]);
    const localEntries = (await readdir(localDir)).sort();
    assert.deepEqual(localEntries, ["local-only.txt"]);
  } finally {
    server.close();
    await rm(dataDir, { recursive: true, force: true });
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient status reports a clear error and exits non-zero when the server is unreachable", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    const port = await unusedPort();
    const start = Date.now();
    const { code, stderr } = await captureConsole(() =>
      runClient(["status", localDir, "--server", `http://127.0.0.1:${port}`], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: status failed/);
    assert.match(stderr, /connection refused/);
    assert.ok(Date.now() - start < 5_000, "must not hang when connection is refused");
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient status reports a clear error and exits non-zero when the server never responds", async () => {
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await withHangingServer(async (baseUrl) => {
      const start = Date.now();
      const { code, stderr } = await captureConsole(() =>
        runClient(["status", localDir, "--server", baseUrl], {}, { timeoutMs: 200 }),
      );

      assert.equal(code, 1);
      assert.match(stderr, /syncbox: status failed/);
      assert.match(stderr, /timed out/);
      assert.ok(Date.now() - start < 5_000, "must not hang waiting for a response");
    });
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});
