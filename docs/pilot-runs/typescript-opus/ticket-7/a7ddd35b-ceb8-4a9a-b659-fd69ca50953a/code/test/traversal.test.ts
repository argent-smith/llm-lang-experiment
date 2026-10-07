import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, readlink, rm, symlink, writeFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { Readable } from "node:stream";
import { after, before, beforeEach, describe, it } from "node:test";

import { BlobStore, InvalidKeyError } from "../src/blobs.js";
import { startServer, type RunningServer } from "../src/server.js";

/** Every file and directory under `dir`, as sorted relative paths. */
async function tree(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { recursive: true });
  return entries.map((e) => e.toString()).sort();
}

/**
 * Keys that escape the store once resolved, or resolve to the root itself.
 * parseKey() never lets them through; BlobStore has to refuse them anyway.
 */
const ESCAPING_KEYS = ["..", "../escape", "a/../../escape", "a/b/../../../escape", ".", "a/..", ""];

describe("BlobStore rejects keys that resolve outside the store", () => {
  let root: string;
  let dataDir: string;
  let store: BlobStore;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-traversal-"));
    // A relative data dir, as --data-dir may be given.
    dataDir = relative(process.cwd(), join(root, "data"));
    store = new BlobStore(dataDir);
    await store.put("a/b/keep", Readable.from(["keep"]));
    await writeFile(join(root, "escape"), "outside");
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  for (const key of ESCAPING_KEYS) {
    it(`refuses ${JSON.stringify(key)} on put, open and delete`, async () => {
      const before = await tree(root);
      await assert.rejects(store.put(key, Readable.from(["evil"])), InvalidKeyError);
      await assert.rejects(store.open(key), InvalidKeyError);
      await assert.rejects(store.delete(key), InvalidKeyError);
      assert.deepEqual(await tree(root), before);
      assert.equal(await readFile(join(root, "escape"), "utf8"), "outside");
    });
  }

  it("leaves no temporary files behind after a refused put", async () => {
    assert.deepEqual(await readdir(join(dataDir, "tmp")), []);
  });
});

describe("directory traversal over HTTP", () => {
  let root: string;
  let dataDir: string;
  let blobsDir: string;
  let outside: string;
  let running: RunningServer;

  /** Sends the path exactly as given (fetch would resolve dot segments). */
  function request(method: string, path: string, body?: string): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
      const req = http.request({ host: "127.0.0.1", port: running.port, method, path }, (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (c: string) => (text += c));
        res.on("end", () => resolve({ status: res.statusCode!, body: text }));
        res.on("error", reject);
      });
      req.on("error", reject);
      req.end(body);
    });
  }

  /** Sends a request line with arbitrary bytes and returns the status code. */
  function rawStatus(method: string, pathBytes: Buffer): Promise<number> {
    return new Promise((resolve, reject) => {
      const socket = net.connect(running.port, "127.0.0.1");
      let response = "";
      socket.setEncoding("latin1");
      socket.on("data", (chunk) => (response += chunk));
      socket.on("end", () => resolve(Number(/^HTTP\/1\.1 (\d{3}) /.exec(response)?.[1] ?? NaN)));
      socket.on("error", reject);
      socket.write(
        Buffer.concat([
          Buffer.from(`${method} `),
          pathBytes,
          Buffer.from(" HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"),
        ]),
      );
    });
  }

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-traversal-http-"));
    dataDir = join(root, "data");
    blobsDir = join(dataDir, "blobs");
    outside = join(root, "outside");
    running = await startServer({ dataDir, port: 0 }, { host: "127.0.0.1" });
  });

  beforeEach(async () => {
    await rm(dataDir, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
    await mkdir(blobsDir, { recursive: true });
    await mkdir(join(outside, "dir"), { recursive: true });
    await writeFile(join(outside, "secret"), "secret");
    await writeFile(join(outside, "dir", "secret"), "secret");
  });

  after(async () => {
    await running.close();
    await rm(root, { recursive: true, force: true });
  });

  // Each of these names an existing file outside the store if resolved
  // naively against <data>/blobs (or against /).
  const TRAVERSAL_PATHS = [
    "/blobs/..",
    "/blobs/../../outside/secret",
    "/blobs/docs/../../../outside/secret",
    "/blobs/%2e%2e/%2e%2e/outside/secret",
    "/blobs/%2E%2E%2F%2E%2E%2Foutside%2Fsecret",
    "/blobs/.%2e/.%2E/outside/secret",
    "/blobs/docs/..%2F..%2F..%2Foutside%2Fsecret",
    "/blobs/%2e%2e",
    "/blobs/./docs",
    "/blobs/docs/.",
    "/blobs//etc/passwd",
    "/blobs/%2Fetc%2Fpasswd",
    "/blobs/%2F%2Fetc/passwd",
  ];

  // Keys that can't be a file name on the server.
  const UNREPRESENTABLE_PATHS = [
    "/blobs/%00",
    "/blobs/a%00/b",
    "/blobs/%",
    "/blobs/%2",
    "/blobs/%zz",
    "/blobs/%FF",
    "/blobs/%C0%AE%C0%AE/secret", // overlong UTF-8 encoding of ".."
    "/blobs/%ED%A0%80", // UTF-8-encoded lone high surrogate
    "/blobs/%ED%B0%80", // UTF-8-encoded lone low surrogate
    "/blobs/%ED%A0%BD%ED%B8%80", // a surrogate pair encoded as two code points (CESU-8)
    `/blobs/${"a".repeat(256)}`,
  ];

  for (const method of ["PUT", "GET", "DELETE"]) {
    it(`${method} answers 400 for traversal and absolute keys and touches nothing outside`, async () => {
      const before = await tree(root);
      for (const path of TRAVERSAL_PATHS) {
        const res = await request(method, path, method === "PUT" ? "evil" : undefined);
        assert.equal(res.status, 400, `${method} ${path}`);
        assert.ok(!res.body.includes("secret"), `${method} ${path}`);
      }
      assert.deepEqual(await tree(root), before);
      assert.equal(await readFile(join(outside, "secret"), "utf8"), "secret");
    });

    it(`${method} answers 400 for keys that can't be file names`, async () => {
      const before = await tree(root);
      for (const path of UNREPRESENTABLE_PATHS) {
        const res = await request(method, path, method === "PUT" ? "x" : undefined);
        assert.equal(res.status, 400, `${method} ${path}`);
      }
      for (const bytes of [[0xff, 0xfe], [0xc0, 0xae, 0xc0, 0xae], [0xed, 0xa0, 0x80]]) {
        const path = Buffer.concat([Buffer.from("/blobs/"), Buffer.from(bytes)]);
        assert.equal(await rawStatus(method, path), 400, `${method} raw ${bytes}`);
      }
      assert.deepEqual(await tree(root), before);
      assert.equal((await request("GET", "/healthz")).status, 200);
    });
  }

  it("accepts names that merely contain dots", async () => {
    for (const key of ["a..b", "...", "..hidden", "dir../file", "%2e%2e%2e"]) {
      assert.equal((await request("PUT", `/blobs/${key}`, key)).status, 201, key);
      assert.equal((await request("GET", `/blobs/${key}`)).body, key);
      assert.equal((await request("DELETE", `/blobs/${key}`)).status, 204, key);
    }
  });

  describe("symbolic links placed in the store", () => {
    beforeEach(async () => {
      await symlink(join(outside, "dir"), join(blobsDir, "linkdir"));
      await symlink(join(outside, "secret"), join(blobsDir, "linkfile"));
      await mkdir(join(blobsDir, "nested"));
      await symlink("../../../outside/dir", join(blobsDir, "nested", "rel"));
    });

    it("refuses keys that lead through a linked directory", async () => {
      const before = [await tree(outside), await tree(blobsDir)];
      for (const path of ["/blobs/linkdir/secret", "/blobs/nested/rel/secret", "/blobs/linkdir/new/file"]) {
        assert.equal((await request("GET", path)).status, 400, `GET ${path}`);
        assert.equal((await request("PUT", path, "evil")).status, 400, `PUT ${path}`);
        assert.equal((await request("DELETE", path)).status, 400, `DELETE ${path}`);
      }
      assert.deepEqual([await tree(outside), await tree(blobsDir)], before);
      assert.equal(await readFile(join(outside, "dir", "secret"), "utf8"), "secret");
      assert.deepEqual(await readdir(join(dataDir, "tmp")).catch(() => []), []);
    });

    it("GET does not follow a link as the blob itself", async () => {
      const res = await request("GET", "/blobs/linkfile");
      assert.equal(res.status, 404);
      assert.ok(!res.body.includes("secret"));
      assert.equal((await request("GET", "/blobs/linkdir")).status, 404);
    });

    it("PUT replaces a link rather than writing through it", async () => {
      assert.equal((await request("PUT", "/blobs/linkfile", "new")).status, 201);
      assert.equal((await request("GET", "/blobs/linkfile")).body, "new");
      assert.equal(await readFile(join(outside, "secret"), "utf8"), "secret");
    });

    it("DELETE removes a link, not what it points to", async () => {
      assert.equal((await request("DELETE", "/blobs/linkfile")).status, 204);
      assert.equal(await readFile(join(outside, "secret"), "utf8"), "secret");
      await assert.rejects(readlink(join(blobsDir, "linkfile")), { code: "ENOENT" });
    });

    it("GET /blobs lists no files behind links", async () => {
      assert.equal((await request("PUT", "/blobs/real", "x")).status, 201);
      const keys = (JSON.parse((await request("GET", "/blobs")).body) as Array<{ key: string }>).map((b) => b.key);
      assert.deepEqual(keys, ["real"]);
    });
  });
});
