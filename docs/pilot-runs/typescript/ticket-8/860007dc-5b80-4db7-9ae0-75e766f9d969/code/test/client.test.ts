import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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

for (const command of ["sync", "status"]) {
  test(`runClient reports '${command}' as not implemented instead of failing silently`, async () => {
    const { code, stderr } = await captureConsole(() =>
      runClient([command, "/tmp/x", "--server", "http://localhost:8080"], {}),
    );
    assert.equal(code, 1);
    assert.match(stderr, /not implemented/);
  });
}

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
