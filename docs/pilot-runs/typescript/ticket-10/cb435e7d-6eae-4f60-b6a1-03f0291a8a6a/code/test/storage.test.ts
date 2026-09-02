import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  InvalidKeyError,
  deleteBlob,
  getBlob,
  keyToPath,
  listBlobs,
  putBlob,
} from "../src/storage.js";

async function withTempDir(
  fn: (dataDir: string) => void | Promise<void>,
): Promise<void> {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-storage-test-"));
  try {
    await fn(dataDir);
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
}

test("keyToPath resolves a plain key under the data dir", async () => {
  await withTempDir((dataDir) => {
    assert.equal(
      keyToPath(dataDir, "docs/readme.txt"),
      join(dataDir, "docs", "readme.txt"),
    );
  });
});

test("keyToPath rejects a key that is exactly ..", async () => {
  await withTempDir((dataDir) => {
    assert.throws(() => keyToPath(dataDir, ".."), InvalidKeyError);
  });
});

test("keyToPath rejects a key that walks above the root", async () => {
  await withTempDir((dataDir) => {
    assert.throws(() => keyToPath(dataDir, "../secret"), InvalidKeyError);
    assert.throws(() => keyToPath(dataDir, "a/../../secret"), InvalidKeyError);
    assert.throws(
      () => keyToPath(dataDir, "a/b/../../../secret"),
      InvalidKeyError,
    );
    assert.throws(() => keyToPath(dataDir, "..secret/../../x"), InvalidKeyError);
  });
});

test("keyToPath rejects an absolute path key", async () => {
  await withTempDir((dataDir) => {
    assert.throws(() => keyToPath(dataDir, "/etc/passwd"), InvalidKeyError);
  });
});

test("keyToPath rejects an empty key", async () => {
  await withTempDir((dataDir) => {
    assert.throws(() => keyToPath(dataDir, ""), InvalidKeyError);
  });
});

test("keyToPath rejects a key that resolves to the root itself", async () => {
  await withTempDir((dataDir) => {
    assert.throws(() => keyToPath(dataDir, "."), InvalidKeyError);
  });
});

test("keyToPath rejects a key containing a null byte", async () => {
  await withTempDir((dataDir) => {
    assert.throws(() => keyToPath(dataDir, "a\0b"), InvalidKeyError);
  });
});

test("keyToPath rejects a key with an unpaired surrogate", async () => {
  await withTempDir((dataDir) => {
    assert.throws(
      () => keyToPath(dataDir, "bad-\uD800-name"),
      InvalidKeyError,
    );
  });
});

test("keyToPath accepts a .. segment that stays inside the root", async () => {
  await withTempDir((dataDir) => {
    assert.equal(keyToPath(dataDir, "a/../b.txt"), join(dataDir, "b.txt"));
  });
});

test("putBlob does not leave a temp file behind after a successful write", async () => {
  await withTempDir(async (dataDir) => {
    await putBlob(dataDir, "file.txt", Buffer.from("content"));

    const entries = await readdir(dataDir);
    assert.deepEqual(entries, ["file.txt"]);
  });
});

test("putBlob cleans up its temp file when the final rename fails", async () => {
  await withTempDir(async (dataDir) => {
    const key = "conflict";
    // Occupy the target path with a directory so rename(tmp -> key) fails.
    await mkdir(join(dataDir, key));

    // A structurally valid key can still be unwritable for OS-level reasons
    // (here: the target is occupied by a directory). That must surface as
    // the same InvalidKeyError structural rejection uses, not a raw fs error.
    await assert.rejects(() => putBlob(dataDir, key, Buffer.from("x")), InvalidKeyError);

    const entries = await readdir(dataDir);
    assert.deepEqual(entries, [key]);
    for (const entry of await readdir(join(dataDir, key))) {
      assert.fail(`unexpected leftover inside ${key}: ${entry}`);
    }
  });
});

test("putBlob rejects with InvalidKeyError when a parent path segment is occupied by a file", async () => {
  await withTempDir(async (dataDir) => {
    // "blocked" exists as a plain file, so mkdir(dirname("blocked/nested.txt"))
    // fails at the OS level (ENOTDIR) even though the key itself passed every
    // structural check. This must still map to InvalidKeyError, not a raw,
    // uncaught fs error.
    await writeFile(join(dataDir, "blocked"), Buffer.from("occupied"));

    await assert.rejects(
      () => putBlob(dataDir, "blocked/nested.txt", Buffer.from("x")),
      InvalidKeyError,
    );
  });
});

test("concurrent putBlob calls to different keys do not interfere", async () => {
  await withTempDir(async (dataDir) => {
    const a = Buffer.alloc(1024 * 1024, 0x01);
    const b = Buffer.alloc(1024 * 1024, 0x02);

    await Promise.all([
      putBlob(dataDir, "a.bin", a),
      putBlob(dataDir, "b.bin", b),
    ]);

    assert.deepEqual(await getBlob(dataDir, "a.bin"), a);
    assert.deepEqual(await getBlob(dataDir, "b.bin"), b);
  });
});

test("concurrent putBlob calls to the same key never produce corrupted content", async () => {
  await withTempDir(async (dataDir) => {
    const key = "race.bin";
    const variants = [
      Buffer.alloc(1024 * 1024, 0xaa),
      Buffer.alloc(1024 * 1024 + 7, 0xbb),
      Buffer.alloc(1024 * 1024 - 3, 0xcc),
    ];

    await Promise.all(variants.map((content) => putBlob(dataDir, key, content)));

    const final = await getBlob(dataDir, key);
    assert.ok(final);
    assert.ok(
      variants.some((v) => v.equals(final)),
      "final content must be exactly one of the concurrent writes, not a mix",
    );

    const entries = await readdir(dataDir);
    assert.deepEqual(entries, [key]);
  });
});

test("a GET racing a PUT of the same key sees fully old or fully new content, never partial", async () => {
  await withTempDir(async (dataDir) => {
    const key = "race-read.bin";
    const oldContent = Buffer.alloc(4 * 1024 * 1024, 0xaa);
    const newContent = Buffer.alloc(4 * 1024 * 1024, 0xbb);
    await putBlob(dataDir, key, oldContent);

    let putSettled = false;
    const putPromise = putBlob(dataDir, key, newContent).then(() => {
      putSettled = true;
    });

    const observed: Buffer[] = [];
    while (!putSettled) {
      const read = await getBlob(dataDir, key);
      if (read) observed.push(read);
    }
    await putPromise;
    const finalRead = await getBlob(dataDir, key);
    assert.ok(finalRead);
    observed.push(finalRead);

    for (const read of observed) {
      const isOld = read.equals(oldContent);
      const isNew = read.equals(newContent);
      assert.ok(
        isOld || isNew,
        `expected a full ${oldContent.length}-byte read, got ${read.length} bytes that match neither variant`,
      );
    }
  });
});

test("getBlob resolves to undefined, not a rejection, when the key is too long for the filesystem to stat", async () => {
  await withTempDir(async (dataDir) => {
    // A structurally valid, well-formed-UTF-8 key can still be unrepresentable
    // on disk: a long run of combining diacritics is a realistic way a client
    // could send a key whose encoded byte length blows past a filesystem's
    // per-component limit (NAME_MAX=255 on ext4). readFile then fails with
    // ENAMETOOLONG, not ENOENT - that must still read as "no such blob", not
    // an uncaught rejection.
    const key = "a" + "́".repeat(200);
    await assert.doesNotReject(async () => {
      assert.equal(await getBlob(dataDir, key), undefined);
    });
  });
});

test("deleteBlob resolves to false, not a rejection, when the key is too long for the filesystem to unlink", async () => {
  await withTempDir(async (dataDir) => {
    const key = "a" + "́".repeat(200);
    await assert.doesNotReject(async () => {
      assert.equal(await deleteBlob(dataDir, key), false);
    });
  });
});

test("getBlob resolves to undefined, not a rejection, when the key resolves to a directory", async () => {
  await withTempDir(async (dataDir) => {
    // "parent" only exists on disk as a directory (because "parent/child.txt"
    // was written under it); reading "parent" itself as a blob fails with
    // EISDIR, not ENOENT. From the API's point of view there is no blob
    // stored at that key either way.
    await putBlob(dataDir, "parent/child.txt", Buffer.from("x"));
    await assert.doesNotReject(async () => {
      assert.equal(await getBlob(dataDir, "parent"), undefined);
    });
  });
});

test("deleteBlob resolves to false, not a rejection, when the key resolves to a directory", async () => {
  await withTempDir(async (dataDir) => {
    await putBlob(dataDir, "parent/child.txt", Buffer.from("x"));
    await assert.doesNotReject(async () => {
      assert.equal(await deleteBlob(dataDir, "parent"), false);
    });
  });
});

test("a legitimate key with an unusual but valid substring round-trips normally", async () => {
  await withTempDir(async (dataDir) => {
    // Combining diacritics, astral-plane characters, and non-ASCII letters
    // are all well-formed UTF-8 that ordinary filesystems store just fine in
    // moderation - only pathological cases (excessive length, directory
    // conflicts, ...) should be treated as unrepresentable.
    const key = "café-\u{1F600}-привет.txt";
    const content = Buffer.from("hello from an unusual key");

    await putBlob(dataDir, key, content);
    assert.deepEqual(await getBlob(dataDir, key), content);
    assert.equal(await deleteBlob(dataDir, key), true);
    assert.equal(await getBlob(dataDir, key), undefined);
  });
});

test("listBlobs excludes stray temp-write files from the listing", async () => {
  await withTempDir(async (dataDir) => {
    await putBlob(dataDir, "real.txt", Buffer.from("real"));
    await writeFile(join(dataDir, "real.txt.syncbox-tmp-deadbeef"), Buffer.from("stray"));

    const blobs = await listBlobs(dataDir);
    assert.deepEqual(blobs.map((b) => b.key), ["real.txt"]);
  });
});
