import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import type { IncomingMessage } from "node:http";
import { test } from "node:test";
import { createApp } from "../src/server.js";
import { getBlob, listBlobs } from "../src/storage.js";
import { push } from "../src/push.js";

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

/**
 * A real server (backed by the real storage) that answers every request
 * normally except the ones `shouldFail` flags, which get a bare 500 - lets a
 * test force one specific upload to fail while the rest succeed for real.
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

test("push uploads every local file missing on the server", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "a.txt"), "hello a");
      await mkdir(join(dir, "sub"));
      await writeFile(join(dir, "sub", "b.txt"), "hello b");

      const result = await push(dir, baseUrl);

      assert.deepEqual(result.uploaded.sort(), ["a.txt", "sub/b.txt"]);
      assert.deepEqual(result.skipped, []);

      const onServer = await getBlob(dataDir, "sub/b.txt");
      assert.equal(onServer?.toString("utf8"), "hello b");
    });
  });
});

test("push does not re-upload a file identical to the server's version", async () => {
  await withServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "same.txt"), "unchanged content");
      await push(dir, baseUrl);

      const result = await push(dir, baseUrl);

      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.skipped, ["same.txt"]);
    });
  });
});

test("push re-uploads a file whose content differs from the server", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "changing.txt");
      await writeFile(filePath, "version one");
      await push(dir, baseUrl);

      await writeFile(filePath, "version two");
      const result = await push(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["changing.txt"]);
      const onServer = await getBlob(dataDir, "changing.txt");
      assert.equal(onServer?.toString("utf8"), "version two");
    });
  });
});

test("push on an empty directory uploads nothing", async () => {
  await withServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      const result = await push(dir, baseUrl);
      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.skipped, []);
    });
  });
});

test("push leaves files already-matching alone while uploading only the changed/missing ones", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "keep.txt"), "keep me");
      await writeFile(join(dir, "change.txt"), "before");
      await push(dir, baseUrl);

      await writeFile(join(dir, "change.txt"), "after");
      await writeFile(join(dir, "new.txt"), "brand new");
      const result = await push(dir, baseUrl);

      assert.deepEqual(result.uploaded.sort(), ["change.txt", "new.txt"]);
      assert.deepEqual(result.skipped, ["keep.txt"]);

      const blobs = await listBlobs(dataDir);
      assert.deepEqual(
        blobs.map((b) => b.key).sort(),
        ["change.txt", "keep.txt", "new.txt"],
      );
    });
  });
});

test("push uses POSIX-style relative paths as blob keys", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await mkdir(join(dir, "a", "b"), { recursive: true });
      await writeFile(join(dir, "a", "b", "c.txt"), "deep file");

      const result = await push(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["a/b/c.txt"]);
      const onServer = await getBlob(dataDir, "a/b/c.txt");
      assert.equal(onServer?.toString("utf8"), "deep file");
    });
  });
});

test("push rejects when the server is unreachable", async () => {
  await withLocalDir(async (dir) => {
    await writeFile(join(dir, "a.txt"), "hello");
    await assert.rejects(() => push(dir, "http://127.0.0.1:1"));
  });
});

test("push continues uploading the remaining files when one upload fails, and reports it", async () => {
  await withFlakyServer(
    (req) => req.method === "PUT" && req.url === "/blobs/bad.txt",
    async (baseUrl, dataDir) => {
      await withLocalDir(async (dir) => {
        await writeFile(join(dir, "good1.txt"), "first");
        await writeFile(join(dir, "bad.txt"), "this one fails");
        await writeFile(join(dir, "good2.txt"), "second");

        const result = await push(dir, baseUrl);

        assert.deepEqual(result.uploaded.sort(), ["good1.txt", "good2.txt"]);
        assert.equal(result.failed.length, 1);
        assert.equal(result.failed[0].key, "bad.txt");
        assert.match(result.failed[0].message, /500/);

        assert.equal(
          (await getBlob(dataDir, "good1.txt"))?.toString("utf8"),
          "first",
        );
        assert.equal(
          (await getBlob(dataDir, "good2.txt"))?.toString("utf8"),
          "second",
        );
        assert.equal(await getBlob(dataDir, "bad.txt"), undefined);
      });
    },
  );
});

test("push times out instead of hanging when the server accepts the connection but never responds", async () => {
  await withHangingServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "a.txt"), "hello");

      const start = Date.now();
      await assert.rejects(
        () => push(dir, baseUrl, { timeoutMs: 200 }),
        /timed out/,
      );
      assert.ok(
        Date.now() - start < 5_000,
        "push must not hang waiting for an unresponsive server",
      );
    });
  });
});
