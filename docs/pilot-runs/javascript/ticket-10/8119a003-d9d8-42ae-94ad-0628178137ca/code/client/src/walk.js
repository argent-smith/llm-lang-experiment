'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');

/**
 * Recursively lists the regular files under rootDir. Each entry's `key` is
 * the POSIX-joined path relative to rootDir (the same convention the server
 * uses for blob keys), built from raw directory-entry names rather than
 * path.join/path.sep so it stays POSIX even if this ever ran on a non-POSIX
 * filesystem. Symlinks are skipped, matching the server's own directory walk.
 */
async function walkDir(rootDir) {
  const results = [];

  async function walk(dir, segments) {
    const entries = await fsp.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const entryPath = path.join(dir, entry.name);
      const entrySegments = [...segments, entry.name];
      if (entry.isDirectory()) {
        await walk(entryPath, entrySegments);
      } else if (entry.isFile()) {
        results.push({ key: entrySegments.join('/'), filePath: entryPath });
      }
    }
  }

  await walk(rootDir, []);
  results.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return results;
}

module.exports = { walkDir };
