import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { createApp } from "../src/server.js";
import { getBlob, putBlob } from "../src/storage.js";
import { sync } from "../src/sync.js";

const OLDER = new Date("2024-01-01T00:00:00.000Z");
const NEWER = new Date("2024-01-01T00:05:00.000Z");
const SAME = new Date("2024-01-01T00:00:00.000Z");

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

/** Establishes a baseline: puts identical content on both sides, then syncs
 * once so the manifest records this key as the last known common state. */
async function seedBaseline(
  dir: string,
  dataDir: string,
  baseUrl: string,
  key: string,
  content: string,
): Promise<void> {
  await writeFile(join(dir, key), content);
  await putBlob(dataDir, key, Buffer.from(content));
  await sync(dir, baseUrl);
}

test("sync uploads a local-only file to the server, keeping the local copy", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "local.txt"), "local only");

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["local.txt"]);
      assert.deepEqual(result.downloaded, []);
      const onServer = await getBlob(dataDir, "local.txt");
      assert.equal(onServer?.toString("utf8"), "local only");
      assert.equal(
        await readFile(join(dir, "local.txt"), "utf8"),
        "local only",
      );
    });
  });
});

test("sync downloads a server-only file to disk, keeping the server copy", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "remote.txt", Buffer.from("remote only"));

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["remote.txt"]);
      assert.deepEqual(result.uploaded, []);
      assert.equal(
        await readFile(join(dir, "remote.txt"), "utf8"),
        "remote only",
      );
      const onServer = await getBlob(dataDir, "remote.txt");
      assert.equal(onServer?.toString("utf8"), "remote only");
    });
  });
});

test("sync leaves an already-matching file alone and records it as unchanged", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "same.txt"), "identical content");
      await putBlob(dataDir, "same.txt", Buffer.from("identical content"));

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.unchanged, ["same.txt"]);
    });
  });
});

test("sync uploads the local version when only the local copy changed since the last sync", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await seedBaseline(dir, dataDir, baseUrl, "file.txt", "original");

      await writeFile(join(dir, "file.txt"), "changed locally");

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["file.txt"]);
      assert.deepEqual(result.downloaded, []);
      const onServer = await getBlob(dataDir, "file.txt");
      assert.equal(onServer?.toString("utf8"), "changed locally");
      assert.equal(
        await readFile(join(dir, "file.txt"), "utf8"),
        "changed locally",
      );
    });
  });
});

test("sync downloads the server version when only the server copy changed since the last sync", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await seedBaseline(dir, dataDir, baseUrl, "file.txt", "original");

      await putBlob(dataDir, "file.txt", Buffer.from("changed on server"));

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["file.txt"]);
      assert.deepEqual(result.uploaded, []);
      assert.equal(
        await readFile(join(dir, "file.txt"), "utf8"),
        "changed on server",
      );
      const onServer = await getBlob(dataDir, "file.txt");
      assert.equal(onServer?.toString("utf8"), "changed on server");
    });
  });
});

test("sync conflict: both sides changed since the last sync, the newer local version wins", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await seedBaseline(dir, dataDir, baseUrl, "file.txt", "original");

      await putBlob(dataDir, "file.txt", Buffer.from("server edit"));
      await utimes(join(dataDir, "file.txt"), OLDER, OLDER);
      await writeFile(join(dir, "file.txt"), "local edit");
      await utimes(join(dir, "file.txt"), NEWER, NEWER);

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["file.txt"]);
      assert.deepEqual(result.downloaded, []);
      const onServer = await getBlob(dataDir, "file.txt");
      assert.equal(onServer?.toString("utf8"), "local edit");
      assert.equal(
        await readFile(join(dir, "file.txt"), "utf8"),
        "local edit",
      );
    });
  });
});

test("sync conflict: both sides changed since the last sync, the newer server version wins", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await seedBaseline(dir, dataDir, baseUrl, "file.txt", "original");

      await writeFile(join(dir, "file.txt"), "local edit");
      await utimes(join(dir, "file.txt"), OLDER, OLDER);
      await putBlob(dataDir, "file.txt", Buffer.from("server edit"));
      await utimes(join(dataDir, "file.txt"), NEWER, NEWER);

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["file.txt"]);
      assert.deepEqual(result.uploaded, []);
      assert.equal(
        await readFile(join(dir, "file.txt"), "utf8"),
        "server edit",
      );
      const onServer = await getBlob(dataDir, "file.txt");
      assert.equal(onServer?.toString("utf8"), "server edit");
    });
  });
});

test("sync conflict: both sides changed with equal mtime, local wins", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await seedBaseline(dir, dataDir, baseUrl, "file.txt", "original");

      await writeFile(join(dir, "file.txt"), "local edit");
      await utimes(join(dir, "file.txt"), SAME, SAME);
      await putBlob(dataDir, "file.txt", Buffer.from("server edit"));
      await utimes(join(dataDir, "file.txt"), SAME, SAME);

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["file.txt"]);
      assert.deepEqual(result.downloaded, []);
      const onServer = await getBlob(dataDir, "file.txt");
      assert.equal(onServer?.toString("utf8"), "local edit");
      assert.equal(
        await readFile(join(dir, "file.txt"), "utf8"),
        "local edit",
      );
    });
  });
});

test("sync on an empty directory against an empty server does nothing", async () => {
  await withServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      const result = await sync(dir, baseUrl);
      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test("sync never deletes: both the pushed local-only file and the pulled remote-only file exist on both sides afterwards", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "local-only.txt"), "keep me");
      await putBlob(dataDir, "remote-only.txt", Buffer.from("keep me too"));

      await sync(dir, baseUrl);

      const localEntries = (await readdir(dir)).filter((e) => e !== ".syncbox");
      assert.deepEqual(localEntries.sort(), ["local-only.txt", "remote-only.txt"]);
      const remoteEntries = (await readdir(dataDir)).sort();
      assert.deepEqual(remoteEntries, ["local-only.txt", "remote-only.txt"]);
    });
  });
});

test("sync combines multiple files and directions correctly, including nested keys", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await seedBaseline(dir, dataDir, baseUrl, "unchanged.txt", "keep me");

      await writeFile(join(dir, "new-local.txt"), "brand new locally");
      await putBlob(
        dataDir,
        "nested/new-remote.txt",
        Buffer.from("brand new remotely"),
      );

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["new-local.txt"]);
      assert.deepEqual(result.downloaded, ["nested/new-remote.txt"]);
      assert.deepEqual(result.unchanged, ["unchanged.txt"]);
      assert.equal(
        await readFile(join(dir, "nested", "new-remote.txt"), "utf8"),
        "brand new remotely",
      );
      const onServer = await getBlob(dataDir, "new-local.txt");
      assert.equal(onServer?.toString("utf8"), "brand new locally");
    });
  });
});

test("sync rejects when the server is unreachable", async () => {
  await withLocalDir(async (dir) => {
    await writeFile(join(dir, "a.txt"), "hello");
    await assert.rejects(() => sync(dir, "http://127.0.0.1:1"));
  });
});
