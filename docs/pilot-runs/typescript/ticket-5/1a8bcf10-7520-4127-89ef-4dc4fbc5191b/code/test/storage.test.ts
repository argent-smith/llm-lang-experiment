import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { InvalidKeyError, keyToPath } from "../src/storage.js";

async function withTempDir(
  fn: (dataDir: string) => void,
): Promise<void> {
  const dataDir = await mkdtemp(join(tmpdir(), "syncbox-storage-test-"));
  try {
    fn(dataDir);
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
