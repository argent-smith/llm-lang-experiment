import * as fs from "node:fs";
import * as path from "node:path";

/**
 * Recursively lists regular files under root, returning POSIX-style paths
 * relative to root (the same key convention the server uses). Symlinks are
 * skipped rather than followed, matching the server's own directory walk.
 */
export function walkFiles(root: string): string[] {
  const results: string[] = [];

  function walk(absDir: string, relSegments: string[]): void {
    const entries = fs.readdirSync(absDir, { withFileTypes: true });
    for (const entry of entries) {
      const absPath = path.join(absDir, entry.name);
      const relPath = [...relSegments, entry.name];

      if (entry.isDirectory()) {
        walk(absPath, relPath);
      } else if (entry.isFile()) {
        results.push(relPath.join("/"));
      }
    }
  }

  walk(root, []);
  return results;
}
