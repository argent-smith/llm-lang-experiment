import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";

import { parseClientArgs, UsageError } from "../src/cli.js";
import { blobUrl, ClientError, SyncboxClient } from "../src/client.js";
import { push } from "../src/push.js";
import {
  collectingReporter,
  freePort,
  remoteBlobs,
  runSyncbox,
  sha256,
  startDroppingServer,
  startServer,
  type TestServer,
  writeTree,
} from "./helpers.js";


describe("parseClientArgs", () => {
  const server = "http://127.0.0.1:8080";

  it("parses each command with --server as a separate or inline value", () => {
    for (const command of ["push", "pull", "status", "sync"] as const) {
      const parsed = parseClientArgs([command, "dir", "--server", server], {});
      assert.deepEqual(parsed, { kind: "command", config: { command, dir: "dir", server: new URL(`${server}/`) } });
    }
    const inline = parseClientArgs(["--server=http://h:1/", "push", "d"], {});
    assert.equal(inline.kind === "command" && inline.config.server.href, "http://h:1/");
  });

  it("falls back to SYNCBOX_SERVER, the flag taking precedence", () => {
    const fromEnv = parseClientArgs(["push", "d"], { SYNCBOX_SERVER: "http://env:1" });
    assert.equal(fromEnv.kind === "command" && fromEnv.config.server.href, "http://env:1/");
    const fromFlag = parseClientArgs(["push", "d", "--server", "http://flag:2"], { SYNCBOX_SERVER: "http://env:1" });
    assert.equal(fromFlag.kind === "command" && fromFlag.config.server.href, "http://flag:2/");
  });

  it("keeps a path prefix of the server URL", () => {
    const parsed = parseClientArgs(["push", "d", "--server", "https://h/syncbox"], {});
    assert.ok(parsed.kind === "command");
    assert.equal(new URL("blobs", parsed.config.server).href, "https://h/syncbox/blobs");
  });

  it("recognizes --help anywhere", () => {
    assert.deepEqual(parseClientArgs(["push", "--help"], {}), { kind: "help" });
    assert.deepEqual(parseClientArgs(["-h"], {}), { kind: "help" });
  });

  it("rejects incomplete or malformed invocations", () => {
    const cases: [string[], NodeJS.ProcessEnv, RegExp][] = [
      [[], {}, /missing command/],
      [["upload", "d", "--server", server], {}, /unknown command: upload/],
      [["push", "--server", server], {}, /push: missing <dir>/],
      [["push", "d"], {}, /--server is required/],
      [["push", "d"], { SYNCBOX_SERVER: "" }, /--server is required/],
      [["push", "d", "--server"], {}, /--server requires a value/],
      [["push", "d", "--server="], {}, /--server is required/],
      [["push", "d", "e", "--server", server], {}, /unexpected argument: e/],
      [["push", "d", "--force", "--server", server], {}, /unknown option: --force/],
      [["push", "d", "--server", "127.0.0.1:8080"], {}, /invalid server URL/],
      [["push", "d", "--server", "ftp://h"], {}, /only http/],
      [["push", "d", "--server", "http://h/?x=1"], {}, /query or fragment/],
    ];
    for (const [argv, env, message] of cases) {
      assert.throws(() => parseClientArgs(argv, env), (err: unknown) => err instanceof UsageError && message.test(err.message), argv.join(" "));
    }
  });
});

describe("blobUrl", () => {
  it("percent-encodes each segment of the key but keeps the slashes", () => {
    const base = new URL("http://h:1/");
    assert.equal(blobUrl(base, "docs/readme.txt").href, "http://h:1/blobs/docs/readme.txt");
    assert.equal(blobUrl(base, "a b/100%/x?y#z").href, "http://h:1/blobs/a%20b/100%25/x%3Fy%23z");
    assert.equal(blobUrl(base, "café/...").href, "http://h:1/blobs/caf%C3%A9/...");
    assert.equal(blobUrl(new URL("http://h/p/"), "k").href, "http://h/p/blobs/k");
  });
});

describe("push", () => {
  let root: string;
  let local: string;
  let server: TestServer;
  let client: SyncboxClient;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-push-"));
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  let n = 0;
  beforeEach(async () => {
    n++;
    local = join(root, `local-${n}`);
    await mkdir(local);
    server = await startServer(join(root, `data-${n}`));
    client = new SyncboxClient(server.url);
  });

  afterEach(async () => {
    client.close();
    await server.close();
  });

  const puts = (): string[] => server.requests.filter((r) => r.startsWith("PUT "));

  it("uploads every file under the directory, keyed by its relative POSIX path", async () => {
    const files = {
      "top.txt": "top",
      "docs/readme.txt": "read me",
      "docs/deep/er/x.bin": randomBytes(1000),
      "empty": "",
      "with space/café 100%#?.txt": "odd name",
      ".hidden": "dotfile",
    };
    await writeTree(local, files);
    await mkdir(join(local, "empty-dir"));

    const reporter = collectingReporter();
    const summary = await push(local, client, reporter);

    const keys = Object.keys(files).sort();
    assert.deepEqual(summary.uploaded, keys);
    assert.deepEqual(summary.unchanged, []);
    assert.deepEqual(reporter.info_, keys.map((k) => `uploaded ${k}`));
    const remote = await remoteBlobs(server);
    assert.deepEqual([...remote.keys()], keys);
    for (const [key, content] of Object.entries(files)) {
      assert.equal(remote.get(key), sha256(content), key);
      // Byte for byte, as stored on the server's disk.
      assert.deepEqual(await readFile(join(server.dataDir, "blobs", ...key.split("/"))), Buffer.from(content));
    }
  });

  it("does not upload anything again when nothing changed", async () => {
    await writeTree(local, { "a.txt": "a", "b/c.txt": "c" });
    await push(local, client, collectingReporter());
    server.requests.length = 0;

    const reporter = collectingReporter();
    const summary = await push(local, client, reporter);

    assert.deepEqual(summary.uploaded, []);
    assert.deepEqual(summary.unchanged, ["a.txt", "b/c.txt"]);
    assert.deepEqual(reporter.info_, []);
    assert.deepEqual(server.requests, ["GET /blobs"]);
  });

  it("uploads only the files whose content changed, even when the size stayed the same", async () => {
    await writeTree(local, { "same.txt": "same", "grown.txt": "v1", "edited.txt": "aaaa" });
    await push(local, client, collectingReporter());
    server.requests.length = 0;

    await writeTree(local, { "grown.txt": "version 2", "edited.txt": "bbbb", "new.txt": "new" });
    const summary = await push(local, client, collectingReporter());

    assert.deepEqual(summary.uploaded, ["edited.txt", "grown.txt", "new.txt"]);
    assert.deepEqual(summary.unchanged, ["same.txt"]);
    assert.deepEqual(puts(), ["PUT /blobs/edited.txt", "PUT /blobs/grown.txt", "PUT /blobs/new.txt"]);
    const remote = await remoteBlobs(server);
    assert.equal(remote.get("grown.txt"), sha256("version 2"));
    assert.equal(remote.get("edited.txt"), sha256("bbbb"));
  });

  it("overwrites a different server version and leaves server-only blobs alone", async () => {
    await writeTree(local, { "shared.txt": "local version" });
    const other = join(root, `other-${n}`);
    await writeTree(other, { "shared.txt": "server version", "server-only.txt": "keep me" });
    await push(other, client, collectingReporter());

    const summary = await push(local, client, collectingReporter());

    assert.deepEqual(summary.uploaded, ["shared.txt"]);
    const remote = await remoteBlobs(server);
    assert.equal(remote.get("shared.txt"), sha256("local version"));
    assert.equal(remote.get("server-only.txt"), sha256("keep me"));
    assert.ok(!server.requests.some((r) => r.startsWith("DELETE ")));
  });

  it("streams large files intact", async () => {
    const big = randomBytes(8 * 1024 * 1024 + 123);
    await writeTree(local, { "big.bin": big });
    await push(local, client, collectingReporter());
    assert.equal((await remoteBlobs(server)).get("big.bin"), sha256(big));
  });

  it("skips symbolic links, special files and names that aren't UTF-8, with a warning", async () => {
    await writeTree(local, { "real.txt": "real", "dir/inner.txt": "inner" });
    await symlink("real.txt", join(local, "link.txt"));
    await symlink("dir", join(local, "linked-dir"));
    await symlink("/etc/passwd", join(local, "outside"));
    await writeFile(Buffer.concat([Buffer.from(join(local, "bad-")), Buffer.from([0xff]), Buffer.from(".txt")]), "x");
    const fifo = join(local, "fifo");
    const mkfifo = spawn("mkfifo", [fifo]);
    const [mkfifoCode] = (await once(mkfifo, "exit")) as [number];
    assert.equal(mkfifoCode, 0);

    const reporter = collectingReporter();
    const summary = await push(local, client, reporter);

    assert.deepEqual(summary.uploaded, ["dir/inner.txt", "real.txt"]);
    assert.equal(summary.skipped, 5);
    assert.deepEqual([...(await remoteBlobs(server)).keys()], ["dir/inner.txt", "real.txt"]);
    const warnings = reporter.warn_.sort();
    assert.deepEqual(warnings, [
      "skipping bad-�.txt: name is not valid UTF-8",
      "skipping fifo: not a regular file",
      "skipping link.txt: symbolic link",
      "skipping linked-dir: symbolic link",
      "skipping outside: symbolic link",
    ]);
  });

  it("fails when the directory is missing or not a directory", async () => {
    await assert.rejects(push(join(local, "nope"), client, collectingReporter()), /nope: no such directory/);
    await writeTree(local, { file: "x" });
    await assert.rejects(push(join(local, "file"), client, collectingReporter()), /file: not a directory/);
    assert.deepEqual(server.requests, []);
  });

  it("fails with the server's reason when it rejects an upload", async () => {
    // `a` can't be stored while the server has `a/b`: a file and a directory.
    const other = join(root, `other-${n}`);
    await writeTree(other, { "a/b": "b" });
    await push(other, client, collectingReporter());
    await writeTree(local, { a: "a" });

    await assert.rejects(
      push(local, client, collectingReporter()),
      (err: unknown) => err instanceof ClientError && /^PUT a: server responded 400 Bad Request: key cannot be stored/.test(err.message),
    );
  });
});

describe("SyncboxClient against a misbehaving server", () => {
  it("reports a server that is not running", async () => {
    const client = new SyncboxClient(new URL(`http://127.0.0.1:${await freePort()}/`));
    await assert.rejects(client.list(), (err: unknown) => err instanceof ClientError && /GET \/blobs: request to .* failed: .*ECONNREFUSED/.test(err.message));
    client.close();
  });

  it("reports a connection dropped without a response", async () => {
    const dropping = await startDroppingServer();
    const client = new SyncboxClient(dropping.url);
    try {
      await assert.rejects(client.list(), (err: unknown) => err instanceof ClientError && /GET \/blobs: request to .* failed/.test(err.message));
      await assert.rejects(client.put("k", Readable.from([Buffer.from("x")])), ClientError);
    } finally {
      client.close();
      dropping.close();
    }
  });

  it("reports responses that aren't a blob list", async () => {
    const replies = [
      [200, "not json"],
      [200, '{"key":"a"}'],
      [500, '{"error":"disk on fire"}'],
    ] as const;
    let i = 0;
    const server = http.createServer((_req, res) => {
      const [status, body] = replies[i++]!;
      res.writeHead(status).end(body);
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const client = new SyncboxClient(new URL(`http://127.0.0.1:${(server.address() as net.AddressInfo).port}/`));
    try {
      await assert.rejects(client.list(), /not valid JSON/);
      await assert.rejects(client.list(), /unexpected response/);
      await assert.rejects(client.list(), /server responded 500 Internal Server Error: disk on fire/);
    } finally {
      client.close();
      server.close();
    }
  });
});

describe("syncbox executable", () => {
  let root: string;
  let server: TestServer;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-cli-"));
    server = await startServer(join(root, "data"));
  });

  after(async () => {
    await server.close();
    await rm(root, { recursive: true, force: true });
  });

  it("pushes a directory, then reports it as unchanged", async () => {
    const dir = join(root, "cli");
    await writeTree(dir, { "x/y.txt": "y", "z.txt": "z" });

    const first = await runSyncbox(["push", dir, "--server", server.url.href]);
    assert.equal(first.code, 0, first.stderr);
    assert.equal(first.stdout, "uploaded x/y.txt\nuploaded z.txt\npush: 2 uploaded, 0 unchanged\n");

    const second = await runSyncbox(["push", dir], { SYNCBOX_SERVER: server.url.origin });
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, "push: 0 uploaded, 2 unchanged\n");
  });

  it("reaches servers on ports fetch() would refuse", async (t) => {
    let badPort: TestServer;
    try {
      badPort = await startServer(join(root, "data-6000"), 6000);
    } catch {
      t.skip("port 6000 is not available");
      return;
    }
    try {
      const dir = join(root, "port");
      await writeTree(dir, { "p.txt": "p" });
      const { code, stderr } = await runSyncbox(["push", dir, "--server", "http://127.0.0.1:6000"]);
      assert.equal(code, 0, stderr);
      assert.equal((await remoteBlobs(badPort)).get("p.txt"), sha256("p"));
    } finally {
      await badPort.close();
    }
  });

  it("exits 1 with a message when the server is unreachable", async () => {
    const dir = join(root, "unreachable");
    await writeTree(dir, { "u.txt": "u" });
    const { code, stdout, stderr } = await runSyncbox(["push", dir, "--server", `http://127.0.0.1:${await freePort()}`]);
    assert.equal(code, 1);
    assert.equal(stdout, "");
    assert.match(stderr, /^syncbox: push failed: GET \/blobs: request to http:\/\/127\.0\.0\.1:\d+ failed: .*ECONNREFUSED/);
  });

  it("exits 1 when the directory does not exist", async () => {
    const { code, stderr } = await runSyncbox(["push", join(root, "missing"), "--server", server.url.href]);
    assert.equal(code, 1);
    assert.match(stderr, /missing: no such directory/);
  });

  it("exits 2 with usage on bad arguments", async () => {
    const noServer = await runSyncbox(["push", root]);
    assert.equal(noServer.code, 2);
    assert.match(noServer.stderr, /--server is required \(or set SYNCBOX_SERVER\)/);
    assert.match(noServer.stderr, /Usage: syncbox <command> <dir> --server <url>/);

    const unknown = await runSyncbox(["upload", root, "--server", server.url.href]);
    assert.equal(unknown.code, 2);
    assert.match(unknown.stderr, /unknown command: upload/);
  });

  it("says that status and sync are not implemented yet", async () => {
    for (const command of ["status", "sync"]) {
      const { code, stdout, stderr } = await runSyncbox([command, root, "--server", server.url.href]);
      assert.equal(code, 1, command);
      assert.equal(stdout, "");
      assert.equal(stderr, `syncbox: '${command}' is not implemented yet (only 'push' and 'pull' are available)\n`);
    }
  });

  it("prints usage on --help", async () => {
    const { code, stdout } = await runSyncbox(["--help"]);
    assert.equal(code, 0);
    assert.match(stdout, /^Usage: syncbox <command> <dir> --server <url>/);
  });
});
