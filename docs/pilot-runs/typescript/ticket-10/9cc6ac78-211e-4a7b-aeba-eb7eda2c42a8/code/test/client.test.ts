import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { createApp } from "../src/server.js";
import { runClient } from "../src/client.js";

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

    const { code, stderr } = await captureConsole(() =>
      runClient(["push", localDir, "--server", "http://127.0.0.1:1"], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: push failed/);
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
    const { code, stderr } = await captureConsole(() =>
      runClient(["pull", localDir, "--server", "http://127.0.0.1:1"], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: pull failed/);
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
    const { code, stderr } = await captureConsole(() =>
      runClient(["status", localDir, "--server", "http://127.0.0.1:1"], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: status failed/);
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});

test("runClient sync uploads local-only and downloads remote-only files against a real server, exits 0", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-server-"));
  const localDir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  const server = createApp(dataDir).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    const baseUrl = `http://127.0.0.1:${port}`;
    await writeFile(join(localDir, "local-only.txt"), "on disk");
    await writeFile(join(dataDir, "remote-only.txt"), "on server");

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
    assert.equal(
      await readFile(join(dataDir, "local-only.txt"), "utf8"),
      "on disk",
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
    const { code, stderr } = await captureConsole(() =>
      runClient(["sync", localDir, "--server", "http://127.0.0.1:1"], {}),
    );

    assert.equal(code, 1);
    assert.match(stderr, /syncbox: sync failed/);
  } finally {
    await rm(localDir, { recursive: true, force: true });
  }
});
