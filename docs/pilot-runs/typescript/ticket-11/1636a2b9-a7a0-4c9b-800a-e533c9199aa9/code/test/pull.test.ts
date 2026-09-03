import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import type { IncomingMessage } from "node:http";
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

/**
 * A real server (backed by the real storage) that answers every request
 * normally except the ones `shouldFail` flags, which get a bare 500 - lets a
 * test force one specific download to fail while the rest succeed for real.
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

test("pull continues downloading the remaining blobs when one download fails, and reports it", async () => {
  await withFlakyServer(
    (req) => req.method === "GET" && req.url === "/blobs/bad.txt",
    async (baseUrl, dataDir) => {
      await withLocalDir(async (dir) => {
        await putBlob(dataDir, "good1.txt", Buffer.from("first"));
        await putBlob(dataDir, "bad.txt", Buffer.from("this one fails"));
        await putBlob(dataDir, "good2.txt", Buffer.from("second"));

        const result = await pull(dir, baseUrl);

        assert.deepEqual(result.downloaded.sort(), ["good1.txt", "good2.txt"]);
        assert.equal(result.failed.length, 1);
        assert.equal(result.failed[0].key, "bad.txt");
        assert.match(result.failed[0].message, /500/);

        assert.equal(await readFile(join(dir, "good1.txt"), "utf8"), "first");
        assert.equal(await readFile(join(dir, "good2.txt"), "utf8"), "second");
        await assert.rejects(() => readFile(join(dir, "bad.txt"), "utf8"));
      });
    },
  );
});

test("pull times out instead of hanging when the server accepts the connection but never responds", async () => {
  await withHangingServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      const start = Date.now();
      await assert.rejects(
        () => pull(dir, baseUrl, { timeoutMs: 200 }),
        /timed out/,
      );
      assert.ok(
        Date.now() - start < 5_000,
        "pull must not hang waiting for an unresponsive server",
      );
    });
  });
});
