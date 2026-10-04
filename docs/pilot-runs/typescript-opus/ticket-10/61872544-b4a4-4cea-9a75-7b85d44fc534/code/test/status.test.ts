import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { cp, lstat, mkdir, mkdtemp, readdir, readFile, rm, symlink, utimes } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";

import { SyncboxClient } from "../src/client.js";
import { pull } from "../src/pull.js";
import { push } from "../src/push.js";
import { formatStatus, status } from "../src/status.js";
import { collectingReporter, freePort, runSyncbox, seed, sha256, startServer, type TestServer, writeTree } from "./helpers.js";

/**
 * Everything observable about a directory tree: each entry's type, size,
 * modification time and (for files) content hash or (for links) target.
 */
async function snapshot(root: string): Promise<Record<string, string>> {
  const result: Record<string, string> = {};
  const rootSt = await lstat(root);
  result["."] = `dir ${rootSt.mtimeMs}`;
  for (const rel of (await readdir(root, { recursive: true })).sort()) {
    const path = join(root, rel);
    const st = await lstat(path);
    if (st.isFile()) {
      result[rel] = `file ${st.size} ${st.mtimeMs} ${sha256(await readFile(path))}`;
    } else if (st.isSymbolicLink()) {
      result[rel] = `link ${st.mtimeMs}`;
    } else {
      result[rel] = `${st.isDirectory() ? "dir" : "other"} ${st.mtimeMs}`;
    }
  }
  return result;
}

describe("status", () => {
  let root: string;
  let local: string;
  let scratch: string;
  let server: TestServer;
  let client: SyncboxClient;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-status-"));
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

  /** Seeds the server and the local directory, then forgets the seeding requests. */
  async function setUp(remote: Record<string, string>, here: Record<string, string>): Promise<void> {
    await seed(server, scratch, remote);
    await writeTree(local, here);
    server.requests.length = 0;
  }

  it("shows a local-only file as an upload and a server-only file as a download", async () => {
    await setUp({ "server-only.txt": "s", "docs/remote.md": "r", "same.txt": "same" }, { "local-only.txt": "l", "a/b/new.bin": "n", "same.txt": "same" });

    const reporter = collectingReporter();
    const report = await status(local, client, reporter);

    assert.deepEqual(report, {
      upload: [
        { key: "a/b/new.bin", why: "missing" },
        { key: "local-only.txt", why: "missing" },
      ],
      download: [
        { key: "docs/remote.md", why: "missing" },
        { key: "server-only.txt", why: "missing" },
      ],
      unchanged: ["same.txt"],
      skipped: 0,
    });
    assert.deepEqual(reporter.info_, []);
    assert.deepEqual(reporter.warn_, []);
  });

  it("shows a file whose content differs in both directions, even when the size is the same", async () => {
    await setUp({ "edited.txt": "bbbb", "grown.txt": "version 2", "same.txt": "same" }, { "edited.txt": "aaaa", "grown.txt": "v1", "same.txt": "same" });

    const report = await status(local, client, collectingReporter());

    const differs = [
      { key: "edited.txt", why: "differs" },
      { key: "grown.txt", why: "differs" },
    ];
    assert.deepEqual(report, { upload: differs, download: differs, unchanged: ["same.txt"], skipped: 0 });
  });

  it("reports nothing to do when both sides have the same content", async () => {
    await setUp({ "a.txt": "a", "b/c.txt": "c" }, { "a.txt": "a", "b/c.txt": "c" });
    const report = await status(local, client, collectingReporter());
    assert.deepEqual(report, { upload: [], download: [], unchanged: ["a.txt", "b/c.txt"], skipped: 0 });
  });

  it("changes nothing locally or on the server: only GET /blobs is requested", async () => {
    await setUp(
      { "server-only.txt": "s", "deep/dir/remote.txt": "r", "differs.txt": "server", "same.txt": "same" },
      { "local-only.txt": "l", "differs.txt": "local!", "same.txt": "same" },
    );
    // Old timestamps, so a rewrite of any file or directory would show.
    const past = new Date("2020-01-01T00:00:00Z");
    for (const rel of [...(await readdir(local, { recursive: true })), "."]) {
      await utimes(join(local, rel), past, past);
    }
    const localBefore = await snapshot(local);
    const serverBefore = await snapshot(server.dataDir);

    const report = await status(local, client, collectingReporter());

    assert.equal(report.upload.length, 2);
    assert.equal(report.download.length, 3);
    assert.deepEqual(server.requests, ["GET /blobs"]);
    assert.deepEqual(await snapshot(local), localBefore);
    assert.deepEqual(await snapshot(server.dataDir), serverBefore);
  });

  it("predicts exactly what push and pull then do", async () => {
    await setUp(
      { "server-only.txt": "s", "differs.txt": "server", "same.txt": "same", "x/y.txt": "y" },
      { "local-only.txt": "l", "differs.txt": "local!", "same.txt": "same", "x/z.txt": "z" },
    );
    const copy = join(root, `copy-${n}`);
    await cp(local, copy, { recursive: true });
    const report = await status(local, client, collectingReporter());

    // Pull into a copy first: that leaves the server as status saw it for push.
    const pulled = await pull(copy, client, collectingReporter());
    assert.deepEqual(pulled.downloaded, report.download.map((t) => t.key));
    const pushed = await push(local, client, collectingReporter());
    assert.deepEqual(pushed.uploaded, report.upload.map((t) => t.key));
    assert.deepEqual(pushed.unchanged, report.unchanged);
  });

  it("skips links and special files on either side, and reports blobs pull couldn't write, without failing", async () => {
    const outside = join(root, `outside-${n}`);
    await writeTree(outside, { "target.txt": "outside", "dir/inner.txt": "outside" });
    await setUp({ "link.txt": "server", "linked-dir/inner.txt": "server", "fifo": "server", "a/b.txt": "b", "ok.txt": "ok" }, { "ok.txt": "ok" });
    await symlink(join(outside, "target.txt"), join(local, "link.txt"));
    await symlink(join(outside, "dir"), join(local, "linked-dir"));
    await mkdir(join(local, "a", "b.txt"), { recursive: true });
    const mkfifo = spawn("mkfifo", [join(local, "fifo")]);
    const [mkfifoCode] = (await once(mkfifo, "exit")) as [number];
    assert.equal(mkfifoCode, 0);
    const before = await snapshot(local);

    const reporter = collectingReporter();
    const report = await status(local, client, reporter);

    assert.deepEqual(report, { upload: [], download: [], unchanged: ["ok.txt"], skipped: 5 });
    // Each problem once, even though both directions run into it.
    assert.deepEqual(reporter.warn_.sort(), [
      "skipping a/b.txt: pull could not write it: it is a directory",
      "skipping fifo: not a regular file",
      "skipping link.txt: symbolic link",
      "skipping linked-dir/inner.txt: linked-dir is a symbolic link",
      "skipping linked-dir: symbolic link",
    ]);
    assert.deepEqual(await snapshot(local), before);
    assert.deepEqual(server.requests, ["GET /blobs"]);
  });

  it("fails when the directory is missing or not a directory", async () => {
    await assert.rejects(status(join(local, "nope"), client, collectingReporter()), /nope: no such directory/);
    await writeTree(local, { file: "x" });
    await assert.rejects(status(join(local, "file"), client, collectingReporter()), /file: not a directory/);
    assert.deepEqual(server.requests, []);
  });
});

describe("formatStatus", () => {
  it("prints one line per transfer with its direction, then a summary", () => {
    const lines = formatStatus({
      upload: [
        { key: "differs.txt", why: "differs" },
        { key: "new.txt", why: "missing" },
      ],
      download: [
        { key: "differs.txt", why: "differs" },
        { key: "remote/x.txt", why: "missing" },
      ],
      unchanged: ["same.txt"],
      skipped: 2,
    });
    assert.deepEqual(lines, [
      "upload    differs.txt  (differs)",
      "upload    new.txt  (not on the server)",
      "download  differs.txt  (differs)",
      "download  remote/x.txt  (not in the directory)",
      "status: 2 to upload, 2 to download, 1 unchanged, 2 skipped",
    ]);
  });

  it("says so when there is nothing to transfer", () => {
    assert.deepEqual(formatStatus({ upload: [], download: [], unchanged: ["a", "b"], skipped: 0 }), [
      "status: in sync, nothing to upload or download (2 unchanged)",
    ]);
  });
});

describe("syncbox status executable", () => {
  let root: string;
  let server: TestServer;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-status-cli-"));
    server = await startServer(join(root, "data"));
    await seed(server, join(root, "seed"), { "remote/only.txt": "r", "differs.txt": "server", "same.txt": "same" });
  });

  after(async () => {
    await server.close();
    await rm(root, { recursive: true, force: true });
  });

  it("prints what would be uploaded and downloaded, changes nothing and exits 0", async () => {
    const dir = join(root, "cli");
    await writeTree(dir, { "local/only.txt": "l", "differs.txt": "local", "same.txt": "same" });
    const before = await snapshot(dir);
    const serverBefore = await snapshot(server.dataDir);
    server.requests.length = 0;

    const { code, stdout, stderr } = await runSyncbox(["status", dir, "--server", server.url.href]);

    assert.equal(code, 0, stderr);
    assert.equal(stderr, "");
    assert.equal(
      stdout,
      [
        "upload    differs.txt  (differs)",
        "upload    local/only.txt  (not on the server)",
        "download  differs.txt  (differs)",
        "download  remote/only.txt  (not in the directory)",
        "status: 2 to upload, 2 to download, 1 unchanged",
        "",
      ].join("\n"),
    );
    assert.deepEqual(server.requests, ["GET /blobs"]);
    assert.deepEqual(await snapshot(dir), before);
    assert.deepEqual(await snapshot(server.dataDir), serverBefore);
  });

  it("exits 0 when in sync, with the server from SYNCBOX_SERVER", async () => {
    const dir = join(root, "in-sync");
    await writeTree(dir, { "remote/only.txt": "r", "differs.txt": "server", "same.txt": "same" });
    const { code, stdout, stderr } = await runSyncbox(["status", dir], { SYNCBOX_SERVER: server.url.origin });
    assert.equal(code, 0, stderr);
    assert.equal(stdout, "status: in sync, nothing to upload or download (3 unchanged)\n");
  });

  it("exits 1 with a message when the server is unreachable", async () => {
    const dir = join(root, "unreachable");
    await writeTree(dir, { "u.txt": "u" });
    const { code, stdout, stderr } = await runSyncbox(["status", dir, "--server", `http://127.0.0.1:${await freePort()}`]);
    assert.equal(code, 1);
    assert.equal(stdout, "");
    assert.match(stderr, /^syncbox: status failed: GET \/blobs: request to http:\/\/127\.0\.0\.1:\d+ failed: .*ECONNREFUSED/);
  });

  it("exits 1 when the directory does not exist", async () => {
    const { code, stderr } = await runSyncbox(["status", join(root, "missing"), "--server", server.url.href]);
    assert.equal(code, 1);
    assert.match(stderr, /^syncbox: status failed: .*missing: no such directory/);
  });

  it("exits 2 with usage when no server is given", async () => {
    const { code, stderr } = await runSyncbox(["status", root]);
    assert.equal(code, 2);
    assert.match(stderr, /--server is required \(or set SYNCBOX_SERVER\)/);
  });
});
