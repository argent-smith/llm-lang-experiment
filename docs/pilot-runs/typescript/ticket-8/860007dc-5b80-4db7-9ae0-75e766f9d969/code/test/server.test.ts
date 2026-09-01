import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import http from "node:http";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
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

/**
 * Like `request`, but sends `path` verbatim as the request-target instead of
 * going through `new URL(...)`, which normalizes literal ".." segments away
 * client-side (per the WHATWG URL spec) before the request ever hits the
 * wire. Traversal keys need to reach the server unmodified to exercise its
 * own defenses.
 */
function requestRawPath(
  baseUrl: string,
  path: string,
  method: string,
): Promise<{ status: number; body: Buffer }> {
  const { hostname, port } = new URL(baseUrl);
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname, port, path, method, headers: { "content-length": "0" } },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () =>
          resolve({
            status: res.statusCode ?? 0,
            body: Buffer.concat(chunks),
          }),
        );
      },
    );
    req.on("error", reject);
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

test("GET /blobs returns an empty array when the store is empty", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(`${baseUrl}/blobs`, { method: "GET" });

    assert.equal(res.status, 200);
    assert.deepEqual(JSON.parse(res.body.toString("utf8")), []);
  });
});

test("GET /blobs lists stored blobs with key/size/sha256/modified_at", async () => {
  await withServer(async (baseUrl) => {
    const content = Buffer.from("list me");
    await request(`${baseUrl}/blobs/top.txt`, { method: "PUT" }, content);

    const res = await request(`${baseUrl}/blobs`, { method: "GET" });

    assert.equal(res.status, 200);
    const parsed = JSON.parse(res.body.toString("utf8"));
    assert.equal(parsed.length, 1);
    const entry = parsed[0];
    assert.equal(entry.key, "top.txt");
    assert.equal(entry.size, content.length);
    assert.equal(
      entry.sha256,
      createHash("sha256").update(content).digest("hex"),
    );
    assert.equal(typeof entry.modified_at, "string");
    assert.equal(new Date(entry.modified_at).toISOString(), entry.modified_at);
  });
});

test("DELETE /blobs/{key} removes an existing blob and returns 204", async () => {
  await withServer(async (baseUrl) => {
    await request(
      `${baseUrl}/blobs/to-delete.txt`,
      { method: "PUT" },
      Buffer.from("bye"),
    );

    const del = await request(`${baseUrl}/blobs/to-delete.txt`, {
      method: "DELETE",
    });
    assert.equal(del.status, 204);
    assert.equal(del.body.length, 0);

    const get = await request(`${baseUrl}/blobs/to-delete.txt`, {
      method: "GET",
    });
    assert.equal(get.status, 404);
  });
});

test("DELETE /blobs/{key} removes the blob from the list", async () => {
  await withServer(async (baseUrl) => {
    await request(
      `${baseUrl}/blobs/keep.txt`,
      { method: "PUT" },
      Buffer.from("keep"),
    );
    await request(
      `${baseUrl}/blobs/remove.txt`,
      { method: "PUT" },
      Buffer.from("remove"),
    );

    await request(`${baseUrl}/blobs/remove.txt`, { method: "DELETE" });

    const res = await request(`${baseUrl}/blobs`, { method: "GET" });
    const keys = JSON.parse(res.body.toString("utf8")).map(
      (entry: { key: string }) => entry.key,
    );
    assert.deepEqual(keys, ["keep.txt"]);
  });
});

test("DELETE /blobs/{key} returns 404 when the blob does not exist", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(`${baseUrl}/blobs/missing.txt`, {
      method: "DELETE",
    });
    assert.equal(res.status, 404);
  });
});

test("DELETE /blobs/{key} on a nested key removes it from disk", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await request(
      `${baseUrl}/blobs/a/b/c.txt`,
      { method: "PUT" },
      Buffer.from("nested"),
    );

    const del = await request(`${baseUrl}/blobs/a/b/c.txt`, {
      method: "DELETE",
    });
    assert.equal(del.status, 204);

    await assert.rejects(() => readFile(join(dataDir, "a", "b", "c.txt")));
  });
});

test("PUT /blobs/{key} rejects a literal .. key with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await requestRawPath(baseUrl, "/blobs/..", "PUT");
    assert.equal(res.status, 400);
  });
});

test("PUT /blobs/{key} rejects a key that walks above the root with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await requestRawPath(baseUrl, "/blobs/../secret.txt", "PUT");
    assert.equal(res.status, 400);
  });
});

test("PUT /blobs/{key} rejects a deeply nested .. escape with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await requestRawPath(
      baseUrl,
      "/blobs/a/b/../../../secret.txt",
      "PUT",
    );
    assert.equal(res.status, 400);
  });
});

test("PUT /blobs/{key} rejects a percent-encoded .. escape with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(
      `${baseUrl}/blobs/%2e%2e%2fsecret.txt`,
      { method: "PUT" },
      Buffer.from("x"),
    );
    assert.equal(res.status, 400);
  });
});

test("PUT /blobs/{key} rejects an absolute-path key with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(
      `${baseUrl}/blobs//etc/passwd`,
      { method: "PUT" },
      Buffer.from("x"),
    );
    assert.equal(res.status, 400);
  });
});

test("PUT /blobs/{key} rejects malformed percent-encoding with 400, not a crash", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(
      `${baseUrl}/blobs/%zz`,
      { method: "PUT" },
      Buffer.from("x"),
    );
    assert.equal(res.status, 400);

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("PUT /blobs/{key} returns 400, not 500, when a structurally valid key can't be written because the target is occupied by a directory", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await mkdir(join(dataDir, "conflict"));

    const res = await request(
      `${baseUrl}/blobs/conflict`,
      { method: "PUT" },
      Buffer.from("x"),
    );
    assert.equal(res.status, 400);

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("PUT /blobs/{key} returns 400, not 500, when a parent path segment is occupied by a file", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await writeFile(join(dataDir, "blocked"), Buffer.from("occupied"));

    const res = await request(
      `${baseUrl}/blobs/blocked/nested.txt`,
      { method: "PUT" },
      Buffer.from("x"),
    );
    assert.equal(res.status, 400);

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("PUT /blobs/{key} with unusual decoded bytes (C1 control chars, astral-plane chars) never returns 500", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(
      `${baseUrl}/blobs/e1%C2%8E%C2%B6%F3%9C%B8%A0`,
      { method: "PUT" },
      Buffer.from("x"),
    );
    assert.ok(
      res.status === 201 || res.status === 400,
      `expected 201 or 400 per the OpenAPI contract, got ${res.status}`,
    );

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("GET /blobs/{key} returns 404, not 500, for a key too long for the filesystem to stat", async () => {
  await withServer(async (baseUrl) => {
    const key = "a" + "́".repeat(200);
    const res = await request(`${baseUrl}/blobs/${encodeURIComponent(key)}`, {
      method: "GET",
    });
    assert.equal(res.status, 404);

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("DELETE /blobs/{key} returns 404, not 500, for a key too long for the filesystem to unlink", async () => {
  await withServer(async (baseUrl) => {
    const key = "a" + "́".repeat(200);
    const res = await request(`${baseUrl}/blobs/${encodeURIComponent(key)}`, {
      method: "DELETE",
    });
    assert.equal(res.status, 404);

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("GET /blobs/{key} returns 404, not 500, when the key resolves to a directory", async () => {
  await withServer(async (baseUrl) => {
    await request(
      `${baseUrl}/blobs/parent/child.txt`,
      { method: "PUT" },
      Buffer.from("x"),
    );

    const res = await request(`${baseUrl}/blobs/parent`, { method: "GET" });
    assert.equal(res.status, 404);

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("DELETE /blobs/{key} returns 404, not 500, when the key resolves to a directory", async () => {
  await withServer(async (baseUrl) => {
    await request(
      `${baseUrl}/blobs/parent/child.txt`,
      { method: "PUT" },
      Buffer.from("x"),
    );

    const res = await request(`${baseUrl}/blobs/parent`, { method: "DELETE" });
    assert.equal(res.status, 404);

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("GET /blobs/{key} with unusual decoded bytes (C1 control chars, astral-plane chars) never returns 500", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(
      `${baseUrl}/blobs/e1%C2%8E%C2%B6%F3%9C%B8%A0`,
      { method: "GET" },
    );
    assert.ok(
      res.status === 200 || res.status === 404 || res.status === 400,
      `expected 200, 404, or 400 per the OpenAPI contract, got ${res.status}`,
    );

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("DELETE /blobs/{key} with unusual decoded bytes (C1 control chars, astral-plane chars) never returns 500", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(
      `${baseUrl}/blobs/e1%C2%8E%C2%B6%F3%9C%B8%A0`,
      { method: "DELETE" },
    );
    assert.ok(
      res.status === 204 || res.status === 404 || res.status === 400,
      `expected 204, 404, or 400 per the OpenAPI contract, got ${res.status}`,
    );

    const health = await request(`${baseUrl}/healthz`, { method: "GET" });
    assert.equal(health.status, 200);
  });
});

test("a legitimate key with an unusual but valid substring round-trips through PUT/GET/DELETE", async () => {
  await withServer(async (baseUrl) => {
    const key = "café-\u{1F600}-привет.txt";
    const content = Buffer.from("hello from an unusual key");
    const encodedKey = key.split("/").map(encodeURIComponent).join("/");

    const put = await request(
      `${baseUrl}/blobs/${encodedKey}`,
      { method: "PUT" },
      content,
    );
    assert.equal(put.status, 201);

    const get = await request(`${baseUrl}/blobs/${encodedKey}`, {
      method: "GET",
    });
    assert.equal(get.status, 200);
    assert.deepEqual(get.body, content);

    const del = await request(`${baseUrl}/blobs/${encodedKey}`, {
      method: "DELETE",
    });
    assert.equal(del.status, 204);

    const getAfterDelete = await request(`${baseUrl}/blobs/${encodedKey}`, {
      method: "GET",
    });
    assert.equal(getAfterDelete.status, 404);
  });
});

test("GET /blobs/{key} rejects a literal .. key with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await requestRawPath(baseUrl, "/blobs/..", "GET");
    assert.equal(res.status, 400);
  });
});

test("GET /blobs/{key} rejects a percent-encoded .. escape with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(`${baseUrl}/blobs/%2e%2e%2fsecret.txt`, {
      method: "GET",
    });
    assert.equal(res.status, 400);
  });
});

test("DELETE /blobs/{key} rejects a literal .. key with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await requestRawPath(baseUrl, "/blobs/..", "DELETE");
    assert.equal(res.status, 400);
  });
});

test("DELETE /blobs/{key} rejects a percent-encoded .. escape with 400", async () => {
  await withServer(async (baseUrl) => {
    const res = await request(`${baseUrl}/blobs/%2e%2e%2fsecret.txt`, {
      method: "DELETE",
    });
    assert.equal(res.status, 400);
  });
});

test("directory traversal attempts do not write files outside the data dir", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await requestRawPath(baseUrl, "/blobs/../escape.txt", "PUT");
    await request(
      `${baseUrl}/blobs/%2e%2e%2fescape2.txt`,
      { method: "PUT" },
      Buffer.from("x"),
    );

    await assert.rejects(() => readFile(join(dataDir, "..", "escape.txt")));
    await assert.rejects(() => readFile(join(dataDir, "..", "escape2.txt")));
  });
});

test("PUT /blobs/{key} does not leave temp files on disk or in the listing", async () => {
  await withServer(async (baseUrl, dataDir) => {
    await request(`${baseUrl}/blobs/clean.txt`, { method: "PUT" }, Buffer.from("clean"));

    const entries = await readdir(dataDir);
    assert.deepEqual(entries, ["clean.txt"]);

    const list = await request(`${baseUrl}/blobs`, { method: "GET" });
    const keys = JSON.parse(list.body.toString("utf8")).map(
      (entry: { key: string }) => entry.key,
    );
    assert.deepEqual(keys, ["clean.txt"]);
  });
});

test("concurrent PUT /blobs/{key} requests to different keys do not interfere", async () => {
  await withServer(async (baseUrl) => {
    const a = Buffer.alloc(512 * 1024, 0x01);
    const b = Buffer.alloc(512 * 1024, 0x02);

    const [resA, resB] = await Promise.all([
      request(`${baseUrl}/blobs/a.bin`, { method: "PUT" }, a),
      request(`${baseUrl}/blobs/b.bin`, { method: "PUT" }, b),
    ]);
    assert.equal(resA.status, 201);
    assert.equal(resB.status, 201);

    const getA = await request(`${baseUrl}/blobs/a.bin`, { method: "GET" });
    const getB = await request(`${baseUrl}/blobs/b.bin`, { method: "GET" });
    assert.deepEqual(getA.body, a);
    assert.deepEqual(getB.body, b);
  });
});

test("concurrent PUT /blobs/{key} requests to the same key never corrupt the stored blob", async () => {
  await withServer(async (baseUrl, dataDir) => {
    const a = Buffer.alloc(512 * 1024, 0x41);
    const b = Buffer.alloc(512 * 1024, 0x42);

    const [resA, resB] = await Promise.all([
      request(`${baseUrl}/blobs/race.bin`, { method: "PUT" }, a),
      request(`${baseUrl}/blobs/race.bin`, { method: "PUT" }, b),
    ]);
    assert.equal(resA.status, 201);
    assert.equal(resB.status, 201);

    const get = await request(`${baseUrl}/blobs/race.bin`, { method: "GET" });
    assert.equal(get.status, 200);
    assert.ok(
      get.body.equals(a) || get.body.equals(b),
      "stored content must be exactly one of the two concurrent writes, not a mix",
    );

    const entries = await readdir(dataDir);
    assert.deepEqual(entries, ["race.bin"]);
  });
});

test("GET /blobs includes nested keys as POSIX paths", async () => {
  await withServer(async (baseUrl) => {
    await request(
      `${baseUrl}/blobs/docs/readme.txt`,
      { method: "PUT" },
      Buffer.from("nested"),
    );
    await request(
      `${baseUrl}/blobs/root.txt`,
      { method: "PUT" },
      Buffer.from("root"),
    );

    const res = await request(`${baseUrl}/blobs`, { method: "GET" });

    assert.equal(res.status, 200);
    const keys = JSON.parse(res.body.toString("utf8"))
      .map((entry: { key: string }) => entry.key)
      .sort();
    assert.deepEqual(keys, ["docs/readme.txt", "root.txt"]);
  });
});
