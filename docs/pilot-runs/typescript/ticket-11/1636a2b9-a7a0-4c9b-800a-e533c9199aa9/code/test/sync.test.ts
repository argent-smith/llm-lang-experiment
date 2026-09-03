import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import type { IncomingMessage } from "node:http";
import { test } from "node:test";
import { createApp } from "../src/server.js";
import { deleteBlob, getBlob, putBlob } from "../src/storage.js";
import { sync } from "../src/sync.js";

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

const OLDER = new Date("2020-01-01T00:00:00.000Z");
const NEWER = new Date("2030-01-01T00:00:00.000Z");

/**
 * A real server (backed by the real storage) that answers every request
 * normally except the ones `shouldFail` flags, which get a bare 500 - lets a
 * test force one specific transfer to fail while the rest succeed for real.
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

test("sync uploads a local-only file to the server", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "local.txt"), "local only");

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["local.txt"]);
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.unchanged, []);
      const onServer = await getBlob(dataDir, "local.txt");
      assert.equal(onServer?.toString("utf8"), "local only");
    });
  });
});

test("sync downloads a server-only file to disk", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "remote.txt", Buffer.from("remote only"));

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.downloaded, ["remote.txt"]);
      assert.deepEqual(result.unchanged, []);
      assert.equal(
        await readFile(join(dir, "remote.txt"), "utf8"),
        "remote only",
      );
    });
  });
});

test("sync uploads the local version when only the local copy changed since the last sync", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "a.txt");
      await writeFile(filePath, "version one");
      await sync(dir, baseUrl); // establishes the common baseline

      await writeFile(filePath, "version two (local)");
      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["a.txt"]);
      assert.deepEqual(result.downloaded, []);
      const onServer = await getBlob(dataDir, "a.txt");
      assert.equal(onServer?.toString("utf8"), "version two (local)");
    });
  });
});

test("sync downloads the server version when only the server copy changed since the last sync", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "a.txt");
      await writeFile(filePath, "version one");
      await sync(dir, baseUrl); // establishes the common baseline

      await putBlob(dataDir, "a.txt", Buffer.from("version two (server)"));
      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["a.txt"]);
      assert.deepEqual(result.uploaded, []);
      assert.equal(
        await readFile(filePath, "utf8"),
        "version two (server)",
      );
    });
  });
});

test("sync conflict: both sides changed, the newer (server) version wins", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "a.txt");
      await writeFile(filePath, "version one");
      await sync(dir, baseUrl);

      await writeFile(filePath, "local edit");
      await utimes(filePath, OLDER, OLDER);
      await putBlob(dataDir, "a.txt", Buffer.from("server edit"));
      await utimes(join(dataDir, "a.txt"), NEWER, NEWER);

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["a.txt"]);
      assert.deepEqual(result.uploaded, []);
      assert.equal(await readFile(filePath, "utf8"), "server edit");
      assert.equal(
        (await getBlob(dataDir, "a.txt"))?.toString("utf8"),
        "server edit",
      );
    });
  });
});

test("sync conflict: both sides changed, the newer (local) version wins", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "a.txt");
      await writeFile(filePath, "version one");
      await sync(dir, baseUrl);

      await putBlob(dataDir, "a.txt", Buffer.from("server edit"));
      await utimes(join(dataDir, "a.txt"), OLDER, OLDER);
      await writeFile(filePath, "local edit");
      await utimes(filePath, NEWER, NEWER);

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["a.txt"]);
      assert.deepEqual(result.downloaded, []);
      assert.equal(await readFile(filePath, "utf8"), "local edit");
      assert.equal(
        (await getBlob(dataDir, "a.txt"))?.toString("utf8"),
        "local edit",
      );
    });
  });
});

test("sync conflict: equal mtime on both sides, the local version wins", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "a.txt");
      await writeFile(filePath, "version one");
      await sync(dir, baseUrl);

      const sameInstant = new Date("2025-06-15T12:00:00.000Z");
      await writeFile(filePath, "local edit");
      await utimes(filePath, sameInstant, sameInstant);
      await putBlob(dataDir, "a.txt", Buffer.from("server edit"));
      await utimes(join(dataDir, "a.txt"), sameInstant, sameInstant);

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["a.txt"]);
      assert.deepEqual(result.downloaded, []);
      assert.equal(await readFile(filePath, "utf8"), "local edit");
      assert.equal(
        (await getBlob(dataDir, "a.txt"))?.toString("utf8"),
        "local edit",
      );
    });
  });
});

test("sync leaves identical files alone on both sides", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "same.txt", Buffer.from("identical"));
      await writeFile(join(dir, "same.txt"), "identical");

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, []);
      assert.deepEqual(result.downloaded, []);
      assert.deepEqual(result.unchanged, ["same.txt"]);
    });
  });
});

test("sync does not propagate a local deletion: the file reappears from the server", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "a.txt");
      await writeFile(filePath, "keep me");
      await sync(dir, baseUrl);

      await rm(filePath);
      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["a.txt"]);
      assert.equal(await readFile(filePath, "utf8"), "keep me");
      const onServer = await getBlob(dataDir, "a.txt");
      assert.equal(onServer?.toString("utf8"), "keep me");
    });
  });
});

test("sync does not propagate a server deletion: the file reappears on the server", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      const filePath = join(dir, "a.txt");
      await writeFile(filePath, "keep me");
      await sync(dir, baseUrl);

      await deleteBlob(dataDir, "a.txt");
      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.uploaded, ["a.txt"]);
      assert.equal(await readFile(filePath, "utf8"), "keep me");
      const onServer = await getBlob(dataDir, "a.txt");
      assert.equal(onServer?.toString("utf8"), "keep me");
    });
  });
});

test("sync creates missing local subdirectories for nested keys downloaded from the server", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await putBlob(dataDir, "a/b/c.txt", Buffer.from("deep file"));

      const result = await sync(dir, baseUrl);

      assert.deepEqual(result.downloaded, ["a/b/c.txt"]);
      assert.equal(
        await readFile(join(dir, "a", "b", "c.txt"), "utf8"),
        "deep file",
      );
    });
  });
});

test("sync does not upload its own manifest bookkeeping file", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "a.txt"), "content");
      await sync(dir, baseUrl);
      const secondRun = await sync(dir, baseUrl);

      assert.deepEqual(secondRun.uploaded, []);
      assert.deepEqual(secondRun.downloaded, []);
      assert.deepEqual(secondRun.unchanged, ["a.txt"]);
      const blob = await getBlob(dataDir, ".syncbox-manifest.json");
      assert.equal(blob, undefined);
    });
  });
});

test("sync rejects when the server is unreachable", async () => {
  await withLocalDir(async (dir) => {
    await writeFile(join(dir, "a.txt"), "content");
    await assert.rejects(() => sync(dir, "http://127.0.0.1:1"));
  });
});

test("sync continues syncing the remaining files when one upload fails, and reports it", async () => {
  await withFlakyServer(
    (req) => req.method === "PUT" && req.url === "/blobs/bad.txt",
    async (baseUrl, dataDir) => {
      await withLocalDir(async (dir) => {
        await writeFile(join(dir, "good.txt"), "uploads fine");
        await writeFile(join(dir, "bad.txt"), "upload fails");

        const result = await sync(dir, baseUrl);

        assert.deepEqual(result.uploaded, ["good.txt"]);
        assert.equal(result.failed.length, 1);
        assert.equal(result.failed[0].key, "bad.txt");
        assert.match(result.failed[0].message, /500/);

        assert.equal(
          (await getBlob(dataDir, "good.txt"))?.toString("utf8"),
          "uploads fine",
        );
        assert.equal(await getBlob(dataDir, "bad.txt"), undefined);
      });
    },
  );
});

test("sync retries a previously-failed key on the next run instead of treating it as resolved", async () => {
  let failFirstAttempt = true;
  await withFlakyServer(
    (req) =>
      failFirstAttempt && req.method === "PUT" && req.url === "/blobs/flaky.txt",
    async (baseUrl, dataDir) => {
      await withLocalDir(async (dir) => {
        await writeFile(join(dir, "flaky.txt"), "eventually uploads");

        const firstRun = await sync(dir, baseUrl);
        assert.equal(firstRun.failed.length, 1);
        assert.equal(await getBlob(dataDir, "flaky.txt"), undefined);

        failFirstAttempt = false;
        const secondRun = await sync(dir, baseUrl);

        assert.deepEqual(secondRun.uploaded, ["flaky.txt"]);
        assert.deepEqual(secondRun.failed, []);
        assert.equal(
          (await getBlob(dataDir, "flaky.txt"))?.toString("utf8"),
          "eventually uploads",
        );
      });
    },
  );
});

test("sync times out instead of hanging when the server accepts the connection but never responds", async () => {
  await withHangingServer(async (baseUrl) => {
    await withLocalDir(async (dir) => {
      await writeFile(join(dir, "a.txt"), "content");

      const start = Date.now();
      await assert.rejects(
        () => sync(dir, baseUrl, { timeoutMs: 200 }),
        /timed out/,
      );
      assert.ok(
        Date.now() - start < 5_000,
        "sync must not hang waiting for an unresponsive server",
      );
    });
  });
});
