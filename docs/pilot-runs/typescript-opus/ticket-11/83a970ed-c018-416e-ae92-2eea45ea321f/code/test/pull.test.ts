import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readdir, readFile, readlink, rm, symlink } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";

import { SyncboxClient } from "../src/client.js";
import { pull } from "../src/pull.js";
import { push } from "../src/push.js";
import { collectingReporter, freePort, runSyncbox, seed, sha256, startServer, type TestServer, writeTree } from "./helpers.js";

/** Every entry under `root` (files, directories, links), as sorted relative paths. */
async function tree(root: string): Promise<string[]> {
  return (await readdir(root, { recursive: true })).sort();
}

/** A server that answers GET /blobs with `list` and everything else with `handler`. */
async function startFakeServer(
  list: unknown[],
  handler: (req: http.IncomingMessage, res: http.ServerResponse) => void,
): Promise<{ url: URL; requests: string[]; close(): Promise<void> }> {
  const requests: string[] = [];
  const server = http.createServer((req, res) => {
    requests.push(`${req.method} ${req.url}`);
    if (req.url === "/blobs") {
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(list));
    } else {
      handler(req, res);
    }
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    url: new URL(`http://127.0.0.1:${(server.address() as net.AddressInfo).port}/`),
    requests,
    async close() {
      server.closeAllConnections();
      server.close();
      await once(server, "close");
    },
  };
}

const meta = (key: string, content: string | Buffer) => ({
  key,
  size: Buffer.byteLength(content),
  sha256: sha256(content),
  modified_at: "2026-01-01T00:00:00.000Z",
});

describe("pull", () => {
  let root: string;
  let local: string;
  let scratch: string;
  let server: TestServer;
  let client: SyncboxClient;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-pull-"));
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  let n = 0;
  beforeEach(async () => {
    n++;
    local = join(root, `local-${n}`);
    scratch = join(root, `scratch-${n}`);
    await mkdir(local);
    server = await startServer(join(root, `data-${n}`));
    client = new SyncboxClient(server.url);
  });

  afterEach(async () => {
    client.close();
    await server.close();
  });

  const gets = (): string[] => server.requests.filter((r) => r.startsWith("GET /blobs/"));
  const writes = (): string[] => server.requests.filter((r) => !r.startsWith("GET "));

  it("downloads every blob into its relative POSIX path, creating directories", async () => {
    const files = {
      "top.txt": "top",
      "docs/readme.txt": "read me",
      "docs/deep/er/x.bin": randomBytes(1000),
      "empty": "",
      "with space/café 100%#?.txt": "odd name",
      ".hidden": "dotfile",
    };
    await seed(server, scratch, files);
    server.requests.length = 0;

    const reporter = collectingReporter();
    const summary = await pull(local, client, reporter);

    const keys = Object.keys(files).sort();
    assert.deepEqual(summary, { downloaded: keys, unchanged: [], skipped: 0, failed: [], notAttempted: 0 });
    assert.deepEqual(reporter.info_, keys.map((k) => `downloaded ${k}`));
    assert.deepEqual(reporter.warn_, []);
    for (const [key, content] of Object.entries(files)) {
      assert.deepEqual(await readFile(join(local, ...key.split("/"))), Buffer.from(content), key);
    }
    // Nothing but the files and their directories, no temporary files.
    assert.deepEqual(await tree(local), [
      ".hidden",
      "docs",
      "docs/deep",
      "docs/deep/er",
      "docs/deep/er/x.bin",
      "docs/readme.txt",
      "empty",
      "top.txt",
      "with space",
      "with space/café 100%#?.txt",
    ]);
    assert.deepEqual(writes(), []);
  });

  it("does not download anything again when nothing changed", async () => {
    await seed(server, scratch, { "a.txt": "a", "b/c.txt": "c" });
    await pull(local, client, collectingReporter());
    server.requests.length = 0;

    const reporter = collectingReporter();
    const summary = await pull(local, client, reporter);

    assert.deepEqual(summary, { downloaded: [], unchanged: ["a.txt", "b/c.txt"], skipped: 0, failed: [], notAttempted: 0 });
    assert.deepEqual(reporter.info_, []);
    assert.deepEqual(server.requests, ["GET /blobs"]);
  });

  it("downloads only what is missing or differs locally, even when the size is the same", async () => {
    await seed(server, scratch, { "same.txt": "same", "grown.txt": "version 2", "edited.txt": "bbbb", "new/file.txt": "new" });
    await writeTree(local, { "same.txt": "same", "grown.txt": "v1", "edited.txt": "aaaa" });
    server.requests.length = 0;

    const summary = await pull(local, client, collectingReporter());

    assert.deepEqual(summary, { downloaded: ["edited.txt", "grown.txt", "new/file.txt"], unchanged: ["same.txt"], skipped: 0, failed: [], notAttempted: 0 });
    assert.deepEqual(gets(), ["GET /blobs/edited.txt", "GET /blobs/grown.txt", "GET /blobs/new/file.txt"]);
    assert.equal(await readFile(join(local, "grown.txt"), "utf8"), "version 2");
    assert.equal(await readFile(join(local, "edited.txt"), "utf8"), "bbbb");
    assert.equal(await readFile(join(local, "new", "file.txt"), "utf8"), "new");
  });

  it("leaves local files the server doesn't have alone and changes nothing on the server", async () => {
    await seed(server, scratch, { "shared.txt": "server version" });
    await writeTree(local, { "shared.txt": "local version", "local-only.txt": "keep me", "dir/also-local.txt": "me too" });
    server.requests.length = 0;

    const summary = await pull(local, client, collectingReporter());

    assert.deepEqual(summary.downloaded, ["shared.txt"]);
    assert.equal(await readFile(join(local, "shared.txt"), "utf8"), "server version");
    assert.equal(await readFile(join(local, "local-only.txt"), "utf8"), "keep me");
    assert.equal(await readFile(join(local, "dir", "also-local.txt"), "utf8"), "me too");
    assert.deepEqual(writes(), []);
  });

  it("mirrors push: pulling into an empty directory reproduces the pushed tree", async () => {
    const files = { "a/b/c.bin": randomBytes(5000), "d.txt": "d", "a/e.txt": "e" };
    await seed(server, scratch, files);
    await pull(local, client, collectingReporter());
    assert.deepEqual(await tree(local), await tree(scratch));
    // And pushing it back changes nothing.
    server.requests.length = 0;
    const back = await push(local, client, collectingReporter());
    assert.deepEqual(back.uploaded, []);
  });

  it("streams large files intact", async () => {
    const big = randomBytes(8 * 1024 * 1024 + 123);
    await seed(server, scratch, { "big.bin": big });
    await pull(local, client, collectingReporter());
    assert.equal(sha256(await readFile(join(local, "big.bin"))), sha256(big));
  });

  it("neither writes through nor replaces symbolic links and special files", async () => {
    const outside = join(root, `outside-${n}`);
    await writeTree(outside, { "target.txt": "outside", "dir/inner.txt": "outside" });
    await seed(server, scratch, { "link.txt": "server", "linked-dir/inner.txt": "server", "fifo": "server", "ok.txt": "ok" });
    await symlink(join(outside, "target.txt"), join(local, "link.txt"));
    await symlink(join(outside, "dir"), join(local, "linked-dir"));
    const mkfifo = spawn("mkfifo", [join(local, "fifo")]);
    const [mkfifoCode] = (await once(mkfifo, "exit")) as [number];
    assert.equal(mkfifoCode, 0);

    const reporter = collectingReporter();
    const summary = await pull(local, client, reporter);

    assert.deepEqual(summary, { downloaded: ["ok.txt"], unchanged: [], skipped: 3, failed: [], notAttempted: 0 });
    assert.deepEqual(reporter.warn_, [
      "skipping fifo: not a regular file",
      "skipping link.txt: symbolic link",
      "skipping linked-dir/inner.txt: linked-dir is a symbolic link",
    ]);
    assert.equal(await readlink(join(local, "link.txt")), join(outside, "target.txt"));
    assert.equal(await readFile(join(outside, "target.txt"), "utf8"), "outside");
    assert.equal(await readFile(join(outside, "dir", "inner.txt"), "utf8"), "outside");
    assert.deepEqual(await tree(outside), ["dir", "dir/inner.txt", "target.txt"]);
  });

  it("reports a blob as failed when a directory is where the file belongs, or a file where a directory belongs", async () => {
    await seed(server, scratch, { "a/b.txt": "b", "c.txt": "c" });
    await mkdir(join(local, "a", "b.txt"), { recursive: true });
    const first = await pull(local, client, collectingReporter());
    assert.deepEqual(first.failed, [{ key: "a/b.txt", message: "cannot write a/b.txt: it is a directory" }]);
    assert.deepEqual(first.downloaded, ["c.txt"]);

    await rm(join(local, "a"), { recursive: true });
    await writeTree(local, { a: "a file" });
    const second = await pull(local, client, collectingReporter());
    assert.deepEqual(second.failed, [{ key: "a/b.txt", message: "cannot write a/b.txt: a is not a directory" }]);
    assert.deepEqual(second.unchanged, ["c.txt"]);
    assert.equal(await readFile(join(local, "a"), "utf8"), "a file");
  });

  it("fails when the directory is missing or not a directory", async () => {
    await assert.rejects(pull(join(local, "nope"), client, collectingReporter()), /nope: no such directory/);
    await writeTree(local, { file: "x" });
    await assert.rejects(pull(join(local, "file"), client, collectingReporter()), /file: not a directory/);
    assert.deepEqual(server.requests, []);
  });
});

describe("pull against a misbehaving server", () => {
  let root: string;
  let local: string;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-pull-bad-"));
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  let n = 0;
  beforeEach(async () => {
    local = join(root, `local-${++n}`, "dir");
    await mkdir(local, { recursive: true });
  });

  async function pullFrom(list: unknown[], handler: (req: http.IncomingMessage, res: http.ServerResponse) => void) {
    const server = await startFakeServer(list, handler);
    const client = new SyncboxClient(server.url);
    const reporter = collectingReporter();
    try {
      const result = await pull(local, client, reporter).then(
        (summary) => ({ summary, error: undefined }),
        (error: unknown) => ({ summary: undefined, error }),
      );
      return { ...result, reporter, requests: server.requests };
    } finally {
      client.close();
      await server.close();
    }
  }

  it("skips keys that are not a relative path inside the directory", async () => {
    const bad = ["../escape.txt", "a/../../escape.txt", "/abs.txt", "a//b", "./x", "x/.", "", "nul\0.txt", "lone\uD800"];
    const { summary, error, reporter, requests } = await pullFrom(
      [...bad.map((k) => meta(k, "evil")), meta("good.txt", "good")],
      (_req, res) => res.writeHead(200).end("good"),
    );
    assert.equal(error, undefined);
    assert.deepEqual(summary, { downloaded: ["good.txt"], unchanged: [], skipped: bad.length, failed: [], notAttempted: 0 });
    assert.equal(reporter.warn_.length, bad.length);
    assert.ok(reporter.warn_.every((w) => w.endsWith(": not a relative path inside the directory")), reporter.warn_.join("\n"));
    assert.deepEqual(requests, ["GET /blobs", "GET /blobs/good.txt"]);
    assert.deepEqual(await tree(join(local, "..")), ["dir", "dir/good.txt"]);
  });

  it("rejects content that doesn't match the listed SHA-256 and keeps the local file", async () => {
    await writeTree(local, { "f.txt": "old" });
    const { summary } = await pullFrom([meta("f.txt", "expected")], (_req, res) => res.writeHead(200).end("tampered"));
    assert.equal(summary?.failed.length, 1);
    assert.match(summary.failed[0]!.message, /^GET f\.txt: received content does not match the SHA-256 the server listed/);
    assert.equal(await readFile(join(local, "f.txt"), "utf8"), "old");
    assert.deepEqual(await tree(local), ["f.txt"]);
  });

  it("keeps the local file when the connection drops mid-download", async () => {
    await writeTree(local, { "f.txt": "old" });
    const { summary } = await pullFrom([meta("f.txt", "x".repeat(1000))], (_req, res) => {
      res.writeHead(200, { "Content-Length": "1000" });
      res.write("x".repeat(10), () => res.destroy());
    });
    assert.equal(summary?.failed.length, 1);
    assert.match(summary.failed[0]!.message, /^GET f\.txt: request to http:\/\/127\.0\.0\.1:\d+ failed/);
    assert.equal(await readFile(join(local, "f.txt"), "utf8"), "old");
    assert.deepEqual(await tree(local), ["f.txt"]);
  });

  it("reports the server's reason when a listed blob can't be downloaded", async () => {
    const { summary } = await pullFrom([meta("gone.txt", "x")], (_req, res) =>
      res.writeHead(404, { "Content-Type": "application/json" }).end('{"error":"blob not found"}'),
    );
    assert.deepEqual(summary?.failed, [{ key: "gone.txt", message: "GET gone.txt: server responded 404 Not Found: blob not found" }]);
    assert.deepEqual(await tree(local), []);
  });
});

describe("syncbox pull executable", () => {
  let root: string;
  let server: TestServer;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-pull-cli-"));
    server = await startServer(join(root, "data"));
    await seed(server, join(root, "seed"), { "x/y.txt": "y", "z.txt": "z" });
  });

  after(async () => {
    await server.close();
    await rm(root, { recursive: true, force: true });
  });

  it("pulls into a directory, then reports it as unchanged", async () => {
    const dir = join(root, "cli");
    await mkdir(dir);

    const first = await runSyncbox(["pull", dir, "--server", server.url.href]);
    assert.equal(first.code, 0, first.stderr);
    assert.equal(first.stdout, "downloaded x/y.txt\ndownloaded z.txt\npull: 2 downloaded, 0 unchanged\n");
    assert.equal(await readFile(join(dir, "x", "y.txt"), "utf8"), "y");

    const second = await runSyncbox(["pull", dir], { SYNCBOX_SERVER: server.url.origin });
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, "pull: 0 downloaded, 2 unchanged\n");
  });

  it("exits 1 with a message when the server is unreachable", async () => {
    const dir = join(root, "unreachable");
    await mkdir(dir);
    const { code, stdout, stderr } = await runSyncbox(["pull", dir, "--server", `http://127.0.0.1:${await freePort()}`]);
    assert.equal(code, 1);
    assert.equal(stdout, "");
    assert.match(stderr, /^syncbox: pull failed: GET \/blobs: cannot connect to http:\/\/127\.0\.0\.1:\d+: connection refused \(ECONNREFUSED\)$/m);
    assert.deepEqual(await tree(dir), []);
  });

  it("exits 1 when the directory does not exist", async () => {
    const { code, stderr } = await runSyncbox(["pull", join(root, "missing"), "--server", server.url.href]);
    assert.equal(code, 1);
    assert.match(stderr, /^syncbox: pull failed: .*missing: no such directory/);
  });

  it("exits 2 with usage when no server is given", async () => {
    const { code, stderr } = await runSyncbox(["pull", root]);
    assert.equal(code, 2);
    assert.match(stderr, /--server is required \(or set SYNCBOX_SERVER\)/);
  });
});
