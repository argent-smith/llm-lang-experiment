// Ticket 11: network errors and partial failures in the client commands.
import assert from "node:assert/strict";
import { once } from "node:events";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, utimes } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";

import { COMMANDS } from "../src/cli.js";
import { SyncboxClient, type ClientOptions } from "../src/client.js";
import { push } from "../src/push.js";
import { runClient } from "../src/run-client.js";
import { sync } from "../src/sync.js";
import {
  collectingReporter,
  freePort,
  remoteBlobs,
  runSyncbox,
  seed,
  sha256,
  startServer,
  type Result,
  type TestServer,
  writeTree,
} from "./helpers.js";

/** File permissions don't stop root: tests that rely on them are skipped then. */
const isRoot = process.getuid?.() === 0;

/** Runs the client in this process, so that its timeouts can be short. */
async function runInProcess(args: string[], env: NodeJS.ProcessEnv, options: ClientOptions): Promise<Result> {
  const out: string[] = [];
  const err: string[] = [];
  const code = await runClient(args, env, { out: (l) => out.push(`${l}\n`), err: (l) => err.push(`${l}\n`) }, options);
  return { code, stdout: out.join(""), stderr: err.join("") };
}

/** Answers like the server would to a failure on its side, after taking in the request body. */
function fail500(req: http.IncomingMessage, res: http.ServerResponse): true {
  req.resume();
  req.on("end", () => res.writeHead(500, { "Content-Type": "application/json" }).end('{"error":"disk on fire"}'));
  return true;
}

/** Takes in the request, then never answers. */
function stall(req: http.IncomingMessage): true {
  req.resume();
  return true;
}

/** A server that accepts connections and then never says a word. */
async function startSilentServer(): Promise<{ url: URL; close(): void }> {
  const sockets = new Set<net.Socket>();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address() as net.AddressInfo;
  return {
    url: new URL(`http://127.0.0.1:${port}/`),
    close() {
      for (const socket of sockets) socket.destroy();
      server.close();
    },
  };
}

/** Every entry under `dir`, sorted: temporary files left behind would show up here. */
async function tree(dir: string): Promise<string[]> {
  return (await readdir(dir, { recursive: true })).sort();
}

describe("client: server unreachable", () => {
  let root: string;
  let env: NodeJS.ProcessEnv;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-errors-unreachable-"));
    env = { XDG_STATE_HOME: join(root, "state") };
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  for (const command of COMMANDS) {
    it(`${command}: connection refused → clear message, exit 1, right away`, async () => {
      const dir = join(root, `refused-${command}`);
      await writeTree(dir, { "f.txt": "f" });
      const started = Date.now();
      const { code, stdout, stderr } = await runSyncbox([command, dir, "--server", `http://127.0.0.1:${await freePort()}`], env);
      assert.ok(Date.now() - started < 5000, "took too long");
      assert.equal(code, 1);
      assert.equal(stdout, "");
      assert.match(
        stderr,
        new RegExp(`^syncbox: ${command} failed: GET /blobs: cannot connect to http://127\\.0\\.0\\.1:\\d+: connection refused \\(ECONNREFUSED\\)\n$`),
      );
      assert.deepEqual(await tree(dir), ["f.txt"]);
    });
  }

  it("names a host name that doesn't resolve", async () => {
    const dir = join(root, "dns");
    await mkdir(dir);
    const started = Date.now();
    const { code, stdout, stderr } = await runSyncbox(["pull", dir, "--server", "http://no-such-host.invalid:8080"]);
    assert.ok(Date.now() - started < 15_000, "took too long");
    assert.equal(code, 1);
    assert.equal(stdout, "");
    assert.match(
      stderr,
      /^syncbox: pull failed: GET \/blobs: cannot connect to http:\/\/no-such-host\.invalid:8080: host name no-such-host\.invalid (not found|could not be resolved) \(E[A-Z_]+\)\n$/,
    );
  });
});

describe("client: server that doesn't respond", () => {
  let root: string;
  let silent: { url: URL; close(): void };

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-errors-timeout-"));
    silent = await startSilentServer();
  });

  after(async () => {
    silent.close();
    await rm(root, { recursive: true, force: true });
  });

  for (const command of COMMANDS) {
    it(`${command}: gives up after the response timeout with a clear message and exit 1`, async () => {
      const dir = join(root, command);
      await writeTree(dir, { "f.txt": "f" });
      const started = Date.now();
      const { code, stdout, stderr } = await runInProcess(
        [command, dir, "--server", silent.url.href],
        { XDG_STATE_HOME: join(root, "state") },
        { responseTimeoutMs: 300 },
      );
      const elapsed = Date.now() - started;
      assert.ok(elapsed >= 250 && elapsed < 5000, `took ${elapsed}ms`);
      assert.equal(code, 1);
      assert.equal(stdout, "");
      assert.match(
        stderr,
        new RegExp(`^syncbox: ${command} failed: GET /blobs: no response from http://127\\.0\\.0\\.1:\\d+: nothing received for 0\\.3s\n$`),
      );
    });
  }

  it("gives up on a body that stops coming, and keeps the local file", async () => {
    const content = "x".repeat(1000);
    const server = http.createServer((req, res) => {
      if (req.url === "/blobs") {
        res.end(JSON.stringify([{ key: "f.txt", size: 1000, sha256: sha256(content), modified_at: "2026-01-01T00:00:00.000Z" }]));
      } else {
        res.writeHead(200, { "Content-Length": "1000" });
        res.write(content.slice(0, 10));
      }
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const dir = join(root, "stalled-body");
    await writeTree(dir, { "f.txt": "old" });
    try {
      const { code, stderr } = await runInProcess(
        ["pull", dir, "--server", `http://127.0.0.1:${(server.address() as net.AddressInfo).port}`],
        {},
        { responseTimeoutMs: 300 },
      );
      assert.equal(code, 1);
      assert.match(stderr, /^ {2}GET f\.txt: no response from http:\/\/127\.0\.0\.1:\d+: nothing received for 0\.3s$/m);
      assert.equal(await readFile(join(dir, "f.txt"), "utf8"), "old");
      assert.deepEqual(await tree(dir), ["f.txt"]);
    } finally {
      server.closeAllConnections();
      server.close();
    }
  });
});

describe("client: partial failure", () => {
  let root: string;
  let local: string;
  let env: NodeJS.ProcessEnv;
  let server: TestServer;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-errors-partial-"));
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  let n = 0;
  beforeEach(async () => {
    n++;
    local = join(root, `local-${n}`);
    await mkdir(local);
    env = { XDG_STATE_HOME: join(root, `state-${n}`) };
    server = await startServer(join(root, `data-${n}`));
  });

  afterEach(async () => {
    await server.close();
  });

  const remoteKeys = async () => [...(await remoteBlobs(server)).keys()];

  it("push: a 5xx on one file → the others are uploaded, the failed one reported, exit 1", async () => {
    await writeTree(local, { "a.txt": "a", "b.txt": "b", "c/d.txt": "d" });
    server.intercept = (req, res) => req.method === "PUT" && req.url === "/blobs/b.txt" && fail500(req, res);

    const first = await runSyncbox(["push", local, "--server", server.url.href]);
    assert.equal(first.code, 1);
    assert.equal(first.stdout, "uploaded a.txt\nuploaded c/d.txt\npush: 2 uploaded, 0 unchanged, 1 failed\n");
    assert.equal(first.stderr, "syncbox: push: 1 file failed:\n  PUT b.txt: server responded 500 Internal Server Error: disk on fire\n");
    assert.deepEqual(await remoteKeys(), ["a.txt", "c/d.txt"]);

    // Once the server is fine again, only what failed is left to do.
    server.intercept = undefined;
    const second = await runSyncbox(["push", local, "--server", server.url.href]);
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, "uploaded b.txt\npush: 1 uploaded, 2 unchanged\n");
  });

  it("push: a connection dropped or a server gone silent on one file doesn't stop the others", async () => {
    await writeTree(local, { "a.txt": "a", "b.txt": "b", "c.txt": "c", "d.txt": "d" });
    server.intercept = (req) => {
      if (req.url === "/blobs/a.txt") req.socket.destroy();
      else if (req.url === "/blobs/c.txt") stall(req);
      else return false;
      return true;
    };

    const { code, stdout, stderr } = await runInProcess(["push", local, "--server", server.url.href], {}, { responseTimeoutMs: 300 });
    assert.equal(code, 1);
    assert.equal(stdout, "uploaded b.txt\nuploaded d.txt\npush: 2 uploaded, 0 unchanged, 2 failed\n");
    assert.match(
      stderr,
      /^syncbox: push: 2 files failed:\n {2}PUT a\.txt: request to http:\/\/127\.0\.0\.1:\d+ failed: [^\n]+\n {2}PUT c\.txt: no response from http:\/\/127\.0\.0\.1:\d+: nothing received for 0\.3s\n$/,
    );
    assert.deepEqual(await remoteKeys(), ["b.txt", "d.txt"]);
  });

  it("push: unreadable local files and directories are reported, the rest is uploaded", { skip: isRoot && "running as root" }, async () => {
    await writeTree(local, { "a.txt": "a", "locked.txt": "l", "sub/x.txt": "x", "z.txt": "z" });
    await chmod(join(local, "locked.txt"), 0o000);
    await chmod(join(local, "sub"), 0o000);
    try {
      const { code, stdout, stderr } = await runSyncbox(["push", local, "--server", server.url.href]);
      assert.equal(code, 1);
      assert.equal(stdout, "uploaded a.txt\nuploaded z.txt\npush: 2 uploaded, 0 unchanged, 2 failed\n");
      assert.match(
        stderr,
        /^syncbox: push: 2 files failed:\n {2}PUT locked\.txt: cannot read the file to upload: EACCES: permission denied[^\n]*\n {2}cannot read directory sub: EACCES: permission denied[^\n]*\n$/,
      );
      assert.deepEqual(await remoteKeys(), ["a.txt", "z.txt"]);
    } finally {
      await chmod(join(local, "locked.txt"), 0o644);
      await chmod(join(local, "sub"), 0o755);
    }
  });

  it("push: once the server is gone altogether, the remaining files aren't tried", async () => {
    await writeTree(local, { "a.txt": "a", "b.txt": "b", "c.txt": "c", "d.txt": "d" });
    // A server of its own, as this one goes away at the first upload.
    const requests: string[] = [];
    const vanishing = http.createServer((req, res) => {
      requests.push(`${req.method} ${req.url}`);
      if (req.url === "/blobs") {
        res.end("[]");
        return;
      }
      vanishing.close();
      vanishing.closeAllConnections();
    });
    vanishing.listen(0, "127.0.0.1");
    await once(vanishing, "listening");
    const client = new SyncboxClient(new URL(`http://127.0.0.1:${(vanishing.address() as net.AddressInfo).port}/`));
    try {
      const summary = await push(local, client, collectingReporter());
      assert.deepEqual(summary.uploaded, []);
      assert.deepEqual(summary.failed.map((f) => f.key), ["a.txt", "b.txt"]);
      assert.match(summary.failed[1]!.message, /^PUT b\.txt: cannot connect to .*ECONNREFUSED/);
      assert.equal(summary.notAttempted, 2);
      assert.deepEqual(requests, ["GET /blobs", "PUT /blobs/a.txt"]);
    } finally {
      client.close();
    }
  });

  it("pull: a failed download → the others are downloaded, the failed one reported, exit 1", async () => {
    await seed(server, join(root, `seed-${n}`), { "a.txt": "a", "b.txt": "b", "c/d.txt": "d" });
    await writeTree(local, { "b.txt": "local b" });
    server.intercept = (req, res) => req.method === "GET" && req.url === "/blobs/b.txt" && fail500(req, res);

    const first = await runSyncbox(["pull", local, "--server", server.url.href]);
    assert.equal(first.code, 1);
    assert.equal(first.stdout, "downloaded a.txt\ndownloaded c/d.txt\npull: 2 downloaded, 0 unchanged, 1 failed\n");
    assert.equal(first.stderr, "syncbox: pull: 1 file failed:\n  GET b.txt: server responded 500 Internal Server Error: disk on fire\n");
    // The local file is untouched, and no temporary file is left behind.
    assert.deepEqual(await tree(local), ["a.txt", "b.txt", "c", "c/d.txt"]);
    assert.equal(await readFile(join(local, "b.txt"), "utf8"), "local b");
    assert.equal(await readFile(join(local, "c", "d.txt"), "utf8"), "d");

    server.intercept = undefined;
    const second = await runSyncbox(["pull", local, "--server", server.url.href]);
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, "downloaded b.txt\npull: 1 downloaded, 2 unchanged\n");
  });

  it("pull: a connection dropped mid-download on one file doesn't stop the others", async () => {
    await seed(server, join(root, `seed-${n}`), { "a.txt": "a".repeat(1000), "b.txt": "b" });
    server.intercept = (req, res) => {
      if (req.url !== "/blobs/a.txt") return false;
      res.writeHead(200, { "Content-Length": "1000" });
      res.write("a".repeat(10), () => res.destroy());
      return true;
    };

    const { code, stdout, stderr } = await runSyncbox(["pull", local, "--server", server.url.href]);
    assert.equal(code, 1);
    assert.equal(stdout, "downloaded b.txt\npull: 1 downloaded, 0 unchanged, 1 failed\n");
    assert.match(stderr, /^syncbox: pull: 1 file failed:\n {2}GET a\.txt: request to http:\/\/127\.0\.0\.1:\d+ failed: [^\n]+\n$/);
    assert.deepEqual(await tree(local), ["b.txt"]);
  });

  it("sync: failures in either direction → the rest is transferred, the failed ones reported, exit 1", async () => {
    // A common state first: f.txt is the same on both sides.
    await writeTree(local, { "f.txt": "v1" });
    assert.equal((await runSyncbox(["sync", local, "--server", server.url.href], env)).code, 0);
    // Then changes on both sides; f.txt only locally, though the server's copy looks newer.
    await writeTree(local, { "f.txt": "v2", "l1.txt": "l1", "l2.txt": "l2" });
    await utimes(join(local, "f.txt"), new Date("2020-01-01"), new Date("2020-01-01"));
    await seed(server, join(root, `seed-${n}`), { "r1.txt": "r1", "r2.txt": "r2" });
    await utimes(join(server.dataDir, "blobs", "f.txt"), new Date("2030-01-01"), new Date("2030-01-01"));
    const failing = new Set(["PUT /blobs/f.txt", "PUT /blobs/l2.txt", "GET /blobs/r2.txt"]);
    server.intercept = (req, res) => failing.has(`${req.method} ${req.url}`) && fail500(req, res);

    const first = await runSyncbox(["sync", local, "--server", server.url.href], env);
    assert.equal(first.code, 1);
    assert.equal(first.stdout, "uploaded l1.txt\ndownloaded r1.txt\nsync: 1 uploaded, 1 downloaded, 0 unchanged, 3 failed\n");
    assert.equal(
      first.stderr,
      [
        "syncbox: sync: 3 files failed:",
        "  PUT f.txt: server responded 500 Internal Server Error: disk on fire",
        "  PUT l2.txt: server responded 500 Internal Server Error: disk on fire",
        "  GET r2.txt: server responded 500 Internal Server Error: disk on fire",
        "",
      ].join("\n"),
    );
    assert.equal(await readFile(join(local, "r1.txt"), "utf8"), "r1");
    assert.deepEqual(await tree(local), ["f.txt", "l1.txt", "l2.txt", "r1.txt"]);

    // The failed f.txt still counts as changed only locally: it goes up,
    // not down, even though the server's copy is newer.
    server.intercept = undefined;
    const second = await runSyncbox(["sync", local, "--server", server.url.href], env);
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, "uploaded f.txt\nuploaded l2.txt\ndownloaded r2.txt\nsync: 2 uploaded, 1 downloaded, 2 unchanged\n");
    assert.equal((await remoteBlobs(server)).get("f.txt"), sha256("v2"));
  });

  it("sync: leaves files in a directory it can't read alone", { skip: isRoot && "running as root" }, async () => {
    await writeTree(local, { "a.txt": "a", "sub/x.txt": "local" });
    await seed(server, join(root, `seed-${n}`), { "sub/x.txt": "server", "sub/y.txt": "y" });
    // Listing it is not allowed, getting at the files in it is.
    await chmod(join(local, "sub"), 0o311);
    const client = new SyncboxClient(server.url);
    try {
      const summary = await sync(local, client, collectingReporter(), { stateDir: join(root, `state-${n}`) });
      assert.deepEqual(summary.uploaded, ["a.txt"]);
      assert.deepEqual(summary.downloaded, []);
      assert.deepEqual(summary.failed.map((f) => f.key), ["sub/"]);
      assert.match(summary.failed[0]!.message, /^cannot read directory sub: EACCES/);
    } finally {
      client.close();
      await chmod(join(local, "sub"), 0o755);
    }
    assert.equal(await readFile(join(local, "sub", "x.txt"), "utf8"), "local");
    assert.equal((await remoteBlobs(server)).get("sub/x.txt"), sha256("server"));
  });

  it("status: an unreadable local file is reported, the rest still compared, exit 1", { skip: isRoot && "running as root" }, async () => {
    await seed(server, join(root, `seed-${n}`), { "locked.txt": "same", "r.txt": "r" });
    await writeTree(local, { "locked.txt": "same", "l.txt": "l" });
    await chmod(join(local, "locked.txt"), 0o000);
    try {
      const { code, stdout, stderr } = await runSyncbox(["status", local, "--server", server.url.href]);
      assert.equal(code, 1);
      assert.equal(stdout, "upload    l.txt  (not on the server)\ndownload  r.txt  (not in the directory)\nstatus: 1 to upload, 1 to download, 0 unchanged, 1 failed\n");
      assert.match(stderr, /^syncbox: status: 1 file failed:\n {2}cannot read locked\.txt: EACCES: permission denied[^\n]*\n$/);
    } finally {
      await chmod(join(local, "locked.txt"), 0o644);
    }
  });
});
