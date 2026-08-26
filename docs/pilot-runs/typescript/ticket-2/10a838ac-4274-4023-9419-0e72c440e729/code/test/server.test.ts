import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import http from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { createApp } from "../src/server.js";

async function withServer(
  fn: (baseUrl: string, dataDir: string) => Promise<void>,
): Promise<void> {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-test-"));
  const server = createApp(dataDir).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    await fn(`http://127.0.0.1:${port}`, dataDir);
  } finally {
    server.close();
    await rm(dataDir, { recursive: true, force: true });
  }
}

function request(
  url: string,
  options: http.RequestOptions,
  body?: Buffer,
): Promise<{ status: number; body: Buffer }> {
  return new Promise((resolve, reject) => {
    const req = http.request(url, options, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () =>
        resolve({
          status: res.statusCode ?? 0,
          body: Buffer.concat(chunks),
        }),
      );
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

test("GET /healthz returns 200", async () => {
  const server = createApp(await mkdtemp(join(tmpdir(), "syncbox-test-"))).listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    const status = await new Promise<number | undefined>((resolve, reject) => {
      http
        .get(`http://127.0.0.1:${port}/healthz`, (res) => {
          res.resume();
          resolve(res.statusCode);
        })
        .on("error", reject);
    });
    assert.equal(status, 200);
  } finally {
    server.close();
  }
});

test("PUT /blobs/{key} stores the blob and returns 201 with key/sha256/size", async () => {
  await withServer(async (baseUrl) => {
    const content = Buffer.from("hello syncbox");
    const res = await request(
      `${baseUrl}/blobs/greeting.txt`,
      { method: "PUT" },
      content,
    );

    assert.equal(res.status, 201);
    const parsed = JSON.parse(res.body.toString("utf8"));
    assert.equal(parsed.key, "greeting.txt");
    assert.equal(parsed.size, content.length);
    assert.equal(
      parsed.sha256,
      createHash("sha256").update(content).digest("hex"),
    );
  });
});

test("PUT /blobs/{key} writes the file to disk under the data dir", async () => {
  await withServer(async (baseUrl, dataDir) => {
    const content = Buffer.from("on disk");
    await request(`${baseUrl}/blobs/file.bin`, { method: "PUT" }, content);

    const onDisk = await readFile(join(dataDir, "file.bin"));
    assert.deepEqual(onDisk, content);
  });
});

test("PUT /blobs/{key} creates nested directories as needed", async () => {
  await withServer(async (baseUrl, dataDir) => {
    const content = Buffer.from("nested content");
    const res = await request(
      `${baseUrl}/blobs/docs/readme.txt`,
      { method: "PUT" },
      content,
    );

    assert.equal(res.status, 201);
    assert.equal(JSON.parse(res.body.toString("utf8")).key, "docs/readme.txt");

    const onDisk = await readFile(join(dataDir, "docs", "readme.txt"));
    assert.deepEqual(onDisk, content);
  });
});

test("PUT /blobs/{key} on an existing key overwrites it", async () => {
  await withServer(async (baseUrl) => {
    await request(
      `${baseUrl}/blobs/overwrite.txt`,
      { method: "PUT" },
      Buffer.from("first"),
    );
    const res = await request(
      `${baseUrl}/blobs/overwrite.txt`,
      { method: "PUT" },
      Buffer.from("second"),
    );

    assert.equal(res.status, 201);
    const get = await request(`${baseUrl}/blobs/overwrite.txt`, {
      method: "GET",
    });
    assert.equal(get.body.toString("utf8"), "second");
  });
});

test("GET /blobs/{key} returns 200 and the stored bytes", async () => {
  await withServer(async (baseUrl) => {
    const content = Buffer.from([0, 1, 2, 3, 255]);
    await request(`${baseUrl}/blobs/bytes.bin`, { method: "PUT" }, content);

    const res = await request(`${baseUrl}/blobs/bytes.bin`, {
      method: "GET",
    });

    assert.equal(res.status, 200);
    assert.deepEqual(res.body, content);
  });
});

test("GET /blobs/{key} on a nested key returns the stored bytes", async () => {
  await withServer(async (baseUrl) => {
    const content = Buffer.from("nested get");
    await request(
      `${baseUrl}/blobs/a/b/c.txt`,
      { method: "PUT" },
      content,
    );

    const res = await request(`${baseUrl}/blobs/a/b/c.txt`, {
      method: "GET",
    });

    assert.equal(res.status, 200);
    assert.deepEqual(res.body, content);
  });
});

test("GET /blobs/{key} returns 404 when the blob does not exist", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(`${baseUrl}/blobs/missing.txt`, {
      method: "GET",
    });
    assert.equal(res.status, 404);
  });
});
