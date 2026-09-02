import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { createApp } from "../src/server.js";
import { putBlob } from "../src/storage.js";
import { pull } from "../src/pull.js";

async function withServer(
  fn: (baseUrl: string, dataDir: string) => Promise<void>,
): Promise<void> {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-server-"));
  const server = createApp(dataDir).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    await fn(`http://127.0.0.1:${port}`, dataDir);
  } finally {
    server.close();
    await rm(dataDir, { recursive: true, force: true });
  }
}

async function withLocalDir(
  fn: (dir: string) => Promise<void>,
): Promise<void> {
  const dir = await mkdtemp(join(tmpdir(), "syncbox-client-"));
  try {
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test("pull downloads every blob missing locally, including nested keys", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "a.txt", Buffer.from("hello a"));
      await putBlob(dataDir, "sub/b.txt", Buffer.from("hello b"));

      const result = await pull(dir, baseUrl);

      assert.deepEqual(result.downloaded.sort(), ["a.txt", "sub/b.txt"]);
      assert.deepEqual(result.skipped, []);

      assert.equal(await readFile(join(dir, "a.txt"), "utf8"), "hello a");
      assert.equal(
        await readFile(join(dir, "sub", "b.txt"), "utf8"),
        "hello b",
      );
    });
  });
});

test("pull does not re-download a file identical to the local version", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "same.txt", Buffer.from("unchanged content"));
      await writeFile(join(dir, "same.txt"), "unchanged content");

      const result = await pull(dir, baseUrl);

      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.skipped, ["same.txt"]);
    });
  });
});

test("pull re-downloads a file whose content differs from the local version", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "changing.txt", Buffer.from("version two"));
      await writeFile(join(dir, "changing.txt"), "version one");

      const result = await pull(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["changing.txt"]);
      assert.equal(
        await readFile(join(dir, "changing.txt"), "utf8"),
        "version two",
      );
    });
  });
});

test("pull from an empty server downloads nothing", async () => {
  await withServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      const result = await pull(dir, baseUrl);
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.skipped, []);
    });
  });
});

test("pull leaves files already-matching alone while downloading only the changed/missing ones", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "keep.txt", Buffer.from("keep me"));
      await putBlob(dataDir, "change.txt", Buffer.from("after"));
      await putBlob(dataDir, "new.txt", Buffer.from("brand new"));
      await writeFile(join(dir, "keep.txt"), "keep me");
      await writeFile(join(dir, "change.txt"), "before");

      const result = await pull(dir, baseUrl);

      assert.deepEqual(result.downloaded.sort(), ["change.txt", "new.txt"]);
      assert.deepEqual(result.skipped, ["keep.txt"]);
      assert.equal(
        await readFile(join(dir, "change.txt"), "utf8"),
        "after",
      );
      assert.equal(
        await readFile(join(dir, "new.txt"), "utf8"),
        "brand new",
      );
    });
  });
});

test("pull creates missing subdirectories for nested keys", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "a/b/c.txt", Buffer.from("deep file"));

      const result = await pull(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["a/b/c.txt"]);
      assert.equal(
        await readFile(join(dir, "a", "b", "c.txt"), "utf8"),
        "deep file",
      );
    });
  });
});

test("pull does not delete or modify local files absent on the server", async () => {
  await withServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      await mkdir(join(dir, "local-only-dir"));
      await writeFile(join(dir, "local-only.txt"), "keep me around");
      await writeFile(
        join(dir, "local-only-dir", "nested.txt"),
        "keep this too",
      );

      const result = await pull(dir, baseUrl);

      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.skipped, []);
      assert.equal(
        await readFile(join(dir, "local-only.txt"), "utf8"),
        "keep me around",
      );
      assert.equal(
        await readFile(join(dir, "local-only-dir", "nested.txt"), "utf8"),
        "keep this too",
      );
    });
  });
});

test("pull rejects when the server is unreachable", async () => {
  await withLocalDir(async (dir) => {
    await assert.rejects(() => pull(dir, "http://127.0.0.1:1"));
  });
});
