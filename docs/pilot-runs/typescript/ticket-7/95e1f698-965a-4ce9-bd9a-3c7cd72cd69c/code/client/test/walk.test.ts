import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { walkFiles } from "../src/walk";

let dir: string;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "syncbox-client-test-"));
});

afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

describe("walkFiles", () => {
  it("returns an empty list for an empty directory", () => {
    expect(walkFiles(dir)).toEqual([]);
  });

  it("lists top-level files", () => {
    fs.writeFileSync(path.join(dir, "a.txt"), "a");
    fs.writeFileSync(path.join(dir, "b.txt"), "b");

    expect(walkFiles(dir).sort()).toEqual(["a.txt", "b.txt"]);
  });

  it("recurses into subdirectories with POSIX-joined relative keys", () => {
    fs.mkdirSync(path.join(dir, "docs", "nested"), { recursive: true });
    fs.writeFileSync(path.join(dir, "docs", "readme.txt"), "hi");
    fs.writeFileSync(path.join(dir, "docs", "nested", "deep.txt"), "deep");

    expect(walkFiles(dir).sort()).toEqual([
      "docs/nested/deep.txt",
      "docs/readme.txt",
    ]);
  });
});
