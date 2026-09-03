'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { walkDir } = require('../src/walk');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-client-test-'));
}

test('walkDir returns an empty list for an empty directory', async () => {
  const dir = tempDir();
  const files = await walkDir(dir);
  assert.deepEqual(files, []);
});

test('walkDir lists top-level files with keys equal to their names', async () => {
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'a');
  fs.writeFileSync(path.join(dir, 'b.txt'), 'b');

  const files = await walkDir(dir);
  assert.deepEqual(files.map((f) => f.key).sort(), ['a.txt', 'b.txt']);
});

test('walkDir recurses into subdirectories and builds POSIX keys', async () => {
  const dir = tempDir();
  fs.mkdirSync(path.join(dir, 'docs'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'docs', 'readme.txt'), '# readme');
  fs.writeFileSync(path.join(dir, 'top.txt'), 'top');

  const files = await walkDir(dir);
  assert.deepEqual(files.map((f) => f.key).sort(), ['docs/readme.txt', 'top.txt']);
});

test('walkDir returns the absolute filesystem path for each entry', async () => {
  const dir = tempDir();
  fs.writeFileSync(path.join(dir, 'a.txt'), 'a');

  const [file] = await walkDir(dir);
  assert.equal(file.filePath, path.join(dir, 'a.txt'));
});

test('walkDir ignores empty subdirectories (they contribute no keys)', async () => {
  const dir = tempDir();
  fs.mkdirSync(path.join(dir, 'empty'), { recursive: true });

  const files = await walkDir(dir);
  assert.deepEqual(files, []);
});
