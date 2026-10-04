import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";

import { SyncboxClient } from "../src/client.js";
import { SyncState } from "../src/state.js";
import { formatSyncSummary, sync } from "../src/sync.js";
import { collectingReporter, freePort, remoteBlobs, runSyncbox, sha256, startServer, type TestServer, writeTree } from "./helpers.js";

const OLD = new Date("2020-01-01T00:00:00.000Z");
const NEW = new Date("2030-01-01T00:00:00.000Z");

describe("sync", () => {
  let root: string;
  let local: string;
  let stateDir: string;
  let server: TestServer;
  let client: SyncboxClient;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-sync-"));
  });

  after(async () => {
    await rm(root, { recursive: true, force: true });
  });

  let n = 0;
  beforeEach(async () => {
    n++;
    local = join(root, `local-${n}`);
    stateDir = join(root, `state-${n}`);
    await mkdir(local);
    server = await startServer(join(root, `data-${n}`));
    client = new SyncboxClient(server.url);
  });

  afterEach(async () => {
    client.close();
    await server.close();
  });

  const run = (reporter = collectingReporter(), dir = local) => sync(dir, client, reporter, { stateDir });

  /** Stores `content` on the server directly, as another client would. */
  const putRemote = (key: string, content: string) => client.put(key, Readable.from([Buffer.from(content)]));
  const remoteContent = async (key: string) => readFile(join(server.dataDir, "blobs", ...key.split("/")), "utf8");
  const localContent = async (key: string, dir = local) => readFile(join(dir, ...key.split("/")), "utf8");
  const setRemoteMtime = (key: string, time: Date) => utimes(join(server.dataDir, "blobs", ...key.split("/")), time, time);
  const setLocalMtime = (key: string, time: Date, dir = local) => utimes(join(dir, ...key.split("/")), time, time);
  const changes = () => server.requests.filter((r) => !r.startsWith("GET "));

  /** A first sync of `files`, after which both sides have them in common. */
  async function syncedBase(files: Record<string, string>): Promise<void> {
    await writeTree(local, files);
    await run();
    assert.deepEqual(Object.fromEntries(await remoteBlobs(server)), Object.fromEntries(Object.entries(files).map(([k, v]) => [k, sha256(v)])));
    server.requests.length = 0;
  }

  it("uploads a local-only file and downloads a server-only file, creating directories", async () => {
    await writeTree(local, { "local-only.txt": "l", "a/b/new.bin": "n", "same.txt": "same" });
    await putRemote("server-only.txt", "s");
    await putRemote("docs/deep/remote.md", "r");
    await putRemote("same.txt", "same");
    server.requests.length = 0;

    const reporter = collectingReporter();
    const summary = await run(reporter);

    assert.deepEqual(summary, {
      uploaded: ["a/b/new.bin", "local-only.txt"],
      downloaded: ["docs/deep/remote.md", "server-only.txt"],
      unchanged: ["same.txt"],
      conflicts: [],
      skipped: 0,
      failed: [],
      notAttempted: 0,
    });
    assert.deepEqual(reporter.info_, [
      "uploaded a/b/new.bin",
      "downloaded docs/deep/remote.md",
      "uploaded local-only.txt",
      "downloaded server-only.txt",
    ]);
    assert.deepEqual(reporter.warn_, []);
    assert.equal(await remoteContent("local-only.txt"), "l");
    assert.equal(await remoteContent("a/b/new.bin"), "n");
    assert.equal(await localContent("server-only.txt"), "s");
    assert.equal(await localContent("docs/deep/remote.md"), "r");
    assert.deepEqual(changes(), ["PUT /blobs/a/b/new.bin", "PUT /blobs/local-only.txt"]);
    // Only the files themselves: no state, no temporary files in the directory.
    assert.deepEqual((await readdir(local, { recursive: true })).sort(), [
      "a",
      "a/b",
      "a/b/new.bin",
      "docs",
      "docs/deep",
      "docs/deep/remote.md",
      "local-only.txt",
      "same.txt",
      "server-only.txt",
    ]);
  });

  it("transfers nothing when run again", async () => {
    await syncedBase({ "a.txt": "a", "b/c.txt": "c" });
    const reporter = collectingReporter();
    const summary = await run(reporter);
    assert.deepEqual(summary, { uploaded: [], downloaded: [], unchanged: ["a.txt", "b/c.txt"], conflicts: [], skipped: 0, failed: [], notAttempted: 0 });
    assert.deepEqual(reporter.info_, []);
    assert.deepEqual(server.requests, ["GET /blobs"]);
  });

  it("uploads a file changed only locally, even when the server's copy has the later time", async () => {
    await syncedBase({ "f.txt": "v1", "other.txt": "o" });
    await writeTree(local, { "f.txt": "local v2" });
    await setLocalMtime("f.txt", OLD);
    await setRemoteMtime("f.txt", NEW);

    const summary = await run();

    assert.deepEqual(summary.uploaded, ["f.txt"]);
    assert.deepEqual(summary.downloaded, []);
    assert.deepEqual(summary.conflicts, []);
    assert.equal(await remoteContent("f.txt"), "local v2");
    assert.equal(await localContent("f.txt"), "local v2");
    assert.deepEqual(changes(), ["PUT /blobs/f.txt"]);
  });

  it("downloads a file changed only on the server, even when the local copy has the later time", async () => {
    await syncedBase({ "dir/f.txt": "v1", "other.txt": "o" });
    await putRemote("dir/f.txt", "server v2");
    await setRemoteMtime("dir/f.txt", OLD);
    await setLocalMtime("dir/f.txt", NEW);
    server.requests.length = 0;

    const summary = await run();

    assert.deepEqual(summary.uploaded, []);
    assert.deepEqual(summary.downloaded, ["dir/f.txt"]);
    assert.deepEqual(summary.conflicts, []);
    assert.equal(await localContent("dir/f.txt"), "server v2");
    assert.equal(await remoteContent("dir/f.txt"), "server v2");
    assert.deepEqual(changes(), []);
  });

  it("settles a file changed on both sides in favour of the later modification time", async () => {
    await syncedBase({ "local-newer.txt": "v1", "server-newer.txt": "v1" });
    await writeTree(local, { "local-newer.txt": "local v2", "server-newer.txt": "local v2" });
    await putRemote("local-newer.txt", "server v2");
    await putRemote("server-newer.txt", "server v2");
    await setLocalMtime("local-newer.txt", new Date("2025-06-01T12:00:00.001Z"));
    await setRemoteMtime("local-newer.txt", new Date("2025-06-01T12:00:00.000Z"));
    await setLocalMtime("server-newer.txt", new Date("2025-06-01T12:00:00.000Z"));
    await setRemoteMtime("server-newer.txt", new Date("2025-06-01T12:00:00.001Z"));
    server.requests.length = 0;

    const reporter = collectingReporter();
    const summary = await run(reporter);

    assert.deepEqual(summary, {
      uploaded: ["local-newer.txt"],
      downloaded: ["server-newer.txt"],
      unchanged: [],
      conflicts: [
        { key: "local-newer.txt", winner: "local", why: "newer", hadBase: true },
        { key: "server-newer.txt", winner: "server", why: "newer", hadBase: true },
      ],
      skipped: 0,
      failed: [],
      notAttempted: 0,
    });
    assert.deepEqual(reporter.info_, [
      "uploaded local-newer.txt  (changed on both sides: local version is newer)",
      "downloaded server-newer.txt  (changed on both sides: server version is newer)",
    ]);
    assert.equal(await remoteContent("local-newer.txt"), "local v2");
    assert.equal(await localContent("local-newer.txt"), "local v2");
    assert.equal(await remoteContent("server-newer.txt"), "server v2");
    assert.equal(await localContent("server-newer.txt"), "server v2");
  });

  it("keeps the local version of a file changed on both sides at the same time", async () => {
    await syncedBase({ "tie.txt": "v1" });
    await writeTree(local, { "tie.txt": "local v2" });
    await putRemote("tie.txt", "server v2");
    const time = new Date("2025-06-01T12:34:56.789Z");
    await setLocalMtime("tie.txt", time);
    await setRemoteMtime("tie.txt", time);
    server.requests.length = 0;

    const reporter = collectingReporter();
    const summary = await run(reporter);

    assert.deepEqual(summary.uploaded, ["tie.txt"]);
    assert.deepEqual(summary.downloaded, []);
    assert.deepEqual(summary.conflicts, [{ key: "tie.txt", winner: "local", why: "same-time", hadBase: true }]);
    assert.deepEqual(reporter.info_, ["uploaded tie.txt  (changed on both sides: same modification time, local version kept)"]);
    assert.equal(await remoteContent("tie.txt"), "local v2");
    assert.equal(await localContent("tie.txt"), "local v2");
  });

  it("settles files that differ on the first sync by modification time too, the local one on a tie", async () => {
    await writeTree(local, { "local-newer.txt": "local", "server-newer.txt": "local", "tie.txt": "local" });
    await putRemote("local-newer.txt", "server");
    await putRemote("server-newer.txt", "server");
    await putRemote("tie.txt", "server");
    await setLocalMtime("local-newer.txt", NEW);
    await setRemoteMtime("local-newer.txt", OLD);
    await setLocalMtime("server-newer.txt", OLD);
    await setRemoteMtime("server-newer.txt", NEW);
    await setLocalMtime("tie.txt", OLD);
    await setRemoteMtime("tie.txt", OLD);

    const reporter = collectingReporter();
    const summary = await run(reporter);

    assert.deepEqual(summary.uploaded, ["local-newer.txt", "tie.txt"]);
    assert.deepEqual(summary.downloaded, ["server-newer.txt"]);
    assert.deepEqual(reporter.info_, [
      "uploaded local-newer.txt  (differs, no previous sync: local version is newer)",
      "downloaded server-newer.txt  (differs, no previous sync: server version is newer)",
      "uploaded tie.txt  (differs, no previous sync: same modification time, local version kept)",
    ]);
    assert.equal(await remoteContent("local-newer.txt"), "local");
    assert.equal(await localContent("server-newer.txt"), "server");
    assert.equal(await remoteContent("tie.txt"), "local");
  });

  it("remembers the result of a conflict as the new common state", async () => {
    await syncedBase({ "f.txt": "v1" });
    await writeTree(local, { "f.txt": "local v2" });
    await putRemote("f.txt", "server v2");
    await setLocalMtime("f.txt", OLD);
    await setRemoteMtime("f.txt", NEW);
    await run();
    assert.equal(await localContent("f.txt"), "server v2");

    // Now only the local side changes, with an old time: it still wins.
    await writeTree(local, { "f.txt": "local v3" });
    await setLocalMtime("f.txt", OLD);
    const summary = await run();
    assert.deepEqual(summary.uploaded, ["f.txt"]);
    assert.deepEqual(summary.conflicts, []);
    assert.equal(await remoteContent("f.txt"), "local v3");
  });

  it("deletes nothing: a file deleted on one side comes back from the other", async () => {
    await syncedBase({ "deleted-locally.txt": "l", "deleted-on-server.txt": "s", "dir/kept.txt": "k" });
    await rm(join(local, "deleted-locally.txt"));
    await rm(join(server.dataDir, "blobs", "deleted-on-server.txt"));

    const summary = await run();

    assert.deepEqual(summary.uploaded, ["deleted-on-server.txt"]);
    assert.deepEqual(summary.downloaded, ["deleted-locally.txt"]);
    assert.equal(await localContent("deleted-locally.txt"), "l");
    assert.equal(await remoteContent("deleted-on-server.txt"), "s");
    assert.ok(changes().every((r) => r.startsWith("PUT ")), changes().join("\n"));
  });

  it("keeps a separate common state for each directory", async () => {
    await syncedBase({ "f.txt": "v1" });
    const other = join(root, `other-${n}`);
    await writeTree(other, { "f.txt": "other" });
    await setLocalMtime("f.txt", OLD, other);
    await setRemoteMtime("f.txt", NEW);

    // Had it taken over the first directory's state, the server's copy would
    // count as unchanged and the other directory's version would be uploaded.
    const summary = await run(collectingReporter(), other);

    assert.deepEqual(summary.downloaded, ["f.txt"]);
    assert.deepEqual(summary.conflicts, [{ key: "f.txt", winner: "server", why: "newer", hadBase: false }]);
    assert.equal(await localContent("f.txt", other), "v1");
  });

  it("ignores an unreadable state file with a warning", async () => {
    await syncedBase({ "f.txt": "v1" });
    const statePath = new SyncState(stateDir, server.url, local).path;
    await writeFile(statePath, "{ not json");
    await writeTree(local, { "f.txt": "local v2" });
    await setLocalMtime("f.txt", OLD);

    const reporter = collectingReporter();
    const summary = await run(reporter);

    // Without the state the local change can't be told apart: the newer server copy wins.
    assert.deepEqual(summary.downloaded, ["f.txt"]);
    assert.deepEqual(reporter.warn_, [`ignoring unusable sync state ${statePath}: every file that differs is treated as changed on both sides`]);
    // And a fresh state is written.
    assert.deepEqual(Object.keys(JSON.parse(await readFile(statePath, "utf8")).files), ["f.txt"]);
  });

  it("fails before transferring anything when it can't keep its state", async () => {
    await writeFile(stateDir, "a file where the state directory belongs");
    await writeTree(local, { "new.txt": "n" });

    await assert.rejects(run(), /^ClientError: cannot use sync state directory /);
    assert.deepEqual(server.requests, []);
  });

  it("skips links and special files with a warning", async () => {
    const outside = join(root, `outside-${n}`);
    await writeTree(outside, { "target.txt": "outside" });
    await writeTree(local, { "ok.txt": "ok" });
    await symlink(join(outside, "target.txt"), join(local, "link.txt"));
    await putRemote("link.txt", "server");

    const reporter = collectingReporter();
    const summary = await run(reporter);

    assert.deepEqual(summary, { uploaded: ["ok.txt"], downloaded: [], unchanged: [], conflicts: [], skipped: 1, failed: [], notAttempted: 0 });
    assert.deepEqual(reporter.warn_, ["skipping link.txt: symbolic link"]);
    assert.equal(await readFile(join(outside, "target.txt"), "utf8"), "outside");
  });

  it("reports a blob that can't be written locally as failed and transfers the rest", async () => {
    await writeTree(local, { "new.txt": "n" });
    await mkdir(join(local, "a", "b.txt"), { recursive: true });
    await putRemote("a/b.txt", "b");
    server.requests.length = 0;

    const summary = await run();
    assert.deepEqual(summary.failed, [{ key: "a/b.txt", message: "cannot write a/b.txt: it is a directory" }]);
    assert.deepEqual(summary.uploaded, ["new.txt"]);
    assert.deepEqual(changes(), ["PUT /blobs/new.txt"]);
  });

  it("fails when the directory is missing or not a directory", async () => {
    await assert.rejects(run(collectingReporter(), join(local, "nope")), /nope: no such directory/);
    await writeTree(local, { file: "x" });
    await assert.rejects(run(collectingReporter(), join(local, "file")), /file: not a directory/);
    assert.deepEqual(server.requests, []);
  });
});

describe("SyncState", () => {
  it("has one state file per directory and server", () => {
    const a = new URL("http://127.0.0.1:8080/");
    const b = new URL("http://127.0.0.1:8081/");
    const path = (server: URL, dir: string) => new SyncState("/state", server, dir).path;
    assert.equal(path(a, "/x"), path(a, "/x"));
    assert.notEqual(path(a, "/x"), path(a, "/y"));
    assert.notEqual(path(a, "/x"), path(b, "/x"));
    assert.match(path(a, "/x"), /^\/state\/[0-9a-f]{64}\.json$/);
  });
});

describe("formatSyncSummary", () => {
  it("counts transfers, unchanged files, conflicts and skipped entries", () => {
    assert.equal(
      formatSyncSummary({
        uploaded: ["a", "b"],
        downloaded: ["c"],
        unchanged: ["d"],
        conflicts: [{ key: "a", winner: "local", why: "newer", hadBase: true }],
        skipped: 2,
        failed: [],
        notAttempted: 0,
      }),
      "sync: 2 uploaded, 1 downloaded, 1 unchanged, 1 settled by modification time, 2 skipped",
    );
    assert.equal(
      formatSyncSummary({ uploaded: [], downloaded: [], unchanged: [], conflicts: [], skipped: 0, failed: [], notAttempted: 0 }),
      "sync: 0 uploaded, 0 downloaded, 0 unchanged",
    );
  });
});

describe("syncbox sync executable", () => {
  let root: string;
  let server: TestServer;
  let env: NodeJS.ProcessEnv;

  before(async () => {
    root = await mkdtemp(join(tmpdir(), "syncbox-sync-cli-"));
    server = await startServer(join(root, "data"));
    env = { XDG_STATE_HOME: join(root, "state") };
  });

  after(async () => {
    await server.close();
    await rm(root, { recursive: true, force: true });
  });

  it("syncs both ways and keeps the common state between runs, outside the directory", async () => {
    const dir = join(root, "cli");
    await writeTree(dir, { "local/only.txt": "l", "f.txt": "v1" });
    const seed = new SyncboxClient(server.url);
    try {
      await seed.put("remote/only.txt", Readable.from([Buffer.from("r")]));
    } finally {
      seed.close();
    }

    const first = await runSyncbox(["sync", dir, "--server", server.url.href], env);
    assert.equal(first.code, 0, first.stderr);
    assert.equal(first.stderr, "");
    assert.equal(first.stdout, "uploaded f.txt\nuploaded local/only.txt\ndownloaded remote/only.txt\nsync: 2 uploaded, 1 downloaded, 0 unchanged\n");
    assert.equal(await readFile(join(dir, "remote", "only.txt"), "utf8"), "r");
    assert.equal((await remoteBlobs(server)).get("local/only.txt"), sha256("l"));
    assert.deepEqual((await readdir(join(root, "state", "syncbox"))).length, 1);
    assert.deepEqual((await readdir(dir, { recursive: true })).sort(), ["f.txt", "local", "local/only.txt", "remote", "remote/only.txt"]);

    // A local change with an older time than the server's copy: only the
    // remembered state shows that it is the local side that changed.
    await writeFile(join(dir, "f.txt"), "v2");
    await utimes(join(dir, "f.txt"), OLD, OLD);
    await utimes(join(server.dataDir, "blobs", "f.txt"), NEW, NEW);
    const second = await runSyncbox(["sync", dir], { ...env, SYNCBOX_SERVER: server.url.origin });
    assert.equal(second.code, 0, second.stderr);
    assert.equal(second.stdout, "uploaded f.txt\nsync: 1 uploaded, 0 downloaded, 2 unchanged\n");
    assert.equal((await remoteBlobs(server)).get("f.txt"), sha256("v2"));
  });

  it("exits 1 with a message when the server is unreachable", async () => {
    const dir = join(root, "unreachable");
    await writeTree(dir, { "u.txt": "u" });
    const { code, stdout, stderr } = await runSyncbox(["sync", dir, "--server", `http://127.0.0.1:${await freePort()}`], env);
    assert.equal(code, 1);
    assert.equal(stdout, "");
    assert.match(stderr, /^syncbox: sync failed: GET \/blobs: cannot connect to http:\/\/127\.0\.0\.1:\d+: connection refused \(ECONNREFUSED\)$/m);
  });

  it("exits 1 when the directory does not exist", async () => {
    const { code, stderr } = await runSyncbox(["sync", join(root, "missing"), "--server", server.url.href], env);
    assert.equal(code, 1);
    assert.match(stderr, /^syncbox: sync failed: .*missing: no such directory/);
  });

  it("exits 2 with usage when no server is given", async () => {
    const { code, stderr } = await runSyncbox(["sync", root], env);
    assert.equal(code, 2);
    assert.match(stderr, /--server is required \(or set SYNCBOX_SERVER\)/);
  });
});
