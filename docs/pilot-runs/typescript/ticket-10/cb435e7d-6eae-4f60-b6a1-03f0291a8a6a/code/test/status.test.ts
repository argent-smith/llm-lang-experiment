import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { createApp } from "../src/server.js";
import { listBlobs, putBlob } from "../src/storage.js";
import { status } from "../src/status.js";

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

test("status reports a locally-new file as to-upload (push direction)", async () => {
  await withServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "new.txt"), "brand new");

      const result = await status(dir, baseUrl);

      assert.deepEqual(result.toUpload, ["new.txt"]);
      assert.deepEqual(result.toDownload, []);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test("status reports a server-only file as to-download (pull direction)", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "remote.txt", Buffer.from("on the server"));

      const result = await status(dir, baseUrl);

      assert.deepEqual(result.toUpload, []);
      assert.deepEqual(result.toDownload, ["remote.txt"]);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test("status reports a file diverged by content in both directions", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "diverged.txt", Buffer.from("server version"));
      await writeFile(join(dir, "diverged.txt"), "local version");

      const result = await status(dir, baseUrl);

      assert.deepEqual(result.toUpload, ["diverged.txt"]);
      assert.deepEqual(result.toDownload, ["diverged.txt"]);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test("status reports a matching file as unchanged", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "same.txt", Buffer.from("identical content"));
      await writeFile(join(dir, "same.txt"), "identical content");

      const result = await status(dir, baseUrl);

      assert.deepEqual(result.toUpload, []);
      assert.deepEqual(result.toDownload, []);
      assert.deepEqual(result.unchanged, ["same.txt"]);
    });
  });
});

test("status on an empty directory against an empty server reports nothing", async () => {
  await withServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      const result = await status(dir, baseUrl);
      assert.deepEqual(result.toUpload, []);
      assert.deepEqual(result.toDownload, []);
      assert.deepEqual(result.unchanged, []);
    });
  });
});

test("status combines multiple files and directions correctly, including nested keys", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "keep.txt", Buffer.from("keep me"));
      await putBlob(dataDir, "server-only/nested.txt", Buffer.from("server nested"));
      await putBlob(dataDir, "diverged.txt", Buffer.from("server side"));
      await writeFile(join(dir, "keep.txt"), "keep me");
      await mkdir(join(dir, "local-only"), { recursive: true });
      await writeFile(join(dir, "local-only", "nested.txt"), "local nested");
      await writeFile(join(dir, "diverged.txt"), "local side");

      const result = await status(dir, baseUrl);

      assert.deepEqual(result.toUpload.sort(), [
        "diverged.txt",
        "local-only/nested.txt",
      ]);
      assert.deepEqual(result.toDownload.sort(), [
        "diverged.txt",
        "server-only/nested.txt",
      ]);
      assert.deepEqual(result.unchanged, ["keep.txt"]);
    });
  });
});

test("status does not upload, download, delete, or otherwise mutate either side", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "remote.txt", Buffer.from("server content"));
      await writeFile(join(dir, "local.txt"), "local content");

      await status(dir, baseUrl);

      const remoteEntries = (await readdir(dataDir)).sort();
      assert.deepEqual(remoteEntries, ["remote.txt"]);
      const blobs = await listBlobs(dataDir);
      assert.deepEqual(blobs.map((b) => b.key), ["remote.txt"]);

      const localEntries = (await readdir(dir)).sort();
      assert.deepEqual(localEntries, ["local.txt"]);
      assert.equal(
        await readFile(join(dir, "local.txt"), "utf8"),
        "local content",
      );
    });
  });
});

test("status rejects when the server is unreachable", async () => {
  await withLocalDir(async (dir) => {
    await assert.rejects(() => status(dir, "http://127.0.0.1:1"));
  });
});
