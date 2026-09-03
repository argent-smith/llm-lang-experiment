'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const { writeFileAtomic, isTempFileName } = require('../src/atomic-write');

function tempDataDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'syncbox-atomic-test-'));
}

test('isTempFileName matches our temp naming pattern and nothing else', () => {
  assert.equal(isTempFileName(`a.txt.${'a'.repeat(32)}.tmp`), true);
  assert.equal(isTempFileName('a.txt'), false);
  assert.equal(isTempFileName('a.txt.tmp'), false);
  assert.equal(isTempFileName(`a.txt.${'g'.repeat(32)}.tmp`), false); // 'g' not hex
  assert.equal(isTempFileName(`a.txt.${'a'.repeat(31)}.tmp`), false); // too short
});

test('writeFileAtomic writes the body and returns sha256/size', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'a.txt');
  const content = Buffer.from('hello world');

  const result = await writeFileAtomic(filePath, Readable.from([content]));

  assert.equal(result.sha256, crypto.createHash('sha256').update(content).digest('hex'));
  assert.equal(result.size, content.length);
  assert.deepEqual(fs.readFileSync(filePath), content);
});

test('writeFileAtomic creates parent directories as needed', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'docs', 'readme.txt');
  const content = Buffer.from('# readme');

  await writeFileAtomic(filePath, Readable.from([content]));

  assert.deepEqual(fs.readFileSync(filePath), content);
});

test('writeFileAtomic leaves no temp file behind on success', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'a.txt');

  await writeFileAtomic(filePath, Readable.from([Buffer.from('content')]));

  const entries = fs.readdirSync(dataDir);
  assert.deepEqual(entries, ['a.txt']);
});

test('the target file only ever contains complete old or complete new content while a write is in flight', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'a.txt');
  const oldContent = Buffer.from('old content, this is the original blob body');
  fs.writeFileSync(filePath, oldContent);

  const newContent = Buffer.from('brand new content, longer than the old one by a fair bit');

  const slowSource = new Readable({
    read() {},
  });

  const writePromise = writeFileAtomic(filePath, slowSource);

  // Push the first half, then read the target mid-write: it must still be
  // the fully-intact old content, never a mix.
  slowSource.push(newContent.subarray(0, 10));
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(fs.readFileSync(filePath), oldContent);

  slowSource.push(newContent.subarray(10));
  slowSource.push(null);

  await writePromise;
  assert.deepEqual(fs.readFileSync(filePath), newContent);
});

test('a temp file is visible under its own name while writing, then disappears', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'a.txt');

  const slowSource = new Readable({ read() {} });
  const writePromise = writeFileAtomic(filePath, slowSource);

  slowSource.push(Buffer.from('partial'));
  await new Promise((resolve) => setTimeout(resolve, 20));

  const entriesWhileWriting = fs.readdirSync(dataDir);
  assert.equal(entriesWhileWriting.length, 1);
  assert.equal(isTempFileName(entriesWhileWriting[0]), true);
  assert.equal(fs.existsSync(filePath), false);

  slowSource.push(null);
  await writePromise;

  assert.deepEqual(fs.readdirSync(dataDir), ['a.txt']);
});

test('writeFileAtomic removes the temp file and rejects when the source errors mid-stream', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'a.txt');

  const failingSource = new Readable({ read() {} });
  const writePromise = writeFileAtomic(filePath, failingSource);

  failingSource.push(Buffer.from('partial'));
  await new Promise((resolve) => setTimeout(resolve, 20));
  failingSource.destroy(new Error('simulated connection drop'));

  await assert.rejects(writePromise);
  assert.deepEqual(fs.readdirSync(dataDir), []);
  assert.equal(fs.existsSync(filePath), false);
});

test('writeFileAtomic does not touch a pre-existing file when the source errors mid-stream', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'a.txt');
  const oldContent = Buffer.from('untouched original');
  fs.writeFileSync(filePath, oldContent);

  const failingSource = new Readable({ read() {} });
  const writePromise = writeFileAtomic(filePath, failingSource);

  failingSource.push(Buffer.from('partial'));
  await new Promise((resolve) => setTimeout(resolve, 20));
  failingSource.destroy(new Error('simulated connection drop'));

  await assert.rejects(writePromise);
  assert.deepEqual(fs.readFileSync(filePath), oldContent);
  assert.deepEqual(fs.readdirSync(dataDir), ['a.txt']);
});

test('concurrent writes to the same path each get their own temp file and do not corrupt each other', async () => {
  const dataDir = tempDataDir();
  const filePath = path.join(dataDir, 'a.txt');

  const contentA = Buffer.alloc(50_000, 'A');
  const contentB = Buffer.alloc(50_000, 'B');

  const [resultA, resultB] = await Promise.all([
    writeFileAtomic(filePath, Readable.from([contentA])),
    writeFileAtomic(filePath, Readable.from([contentB])),
  ]);

  const finalContent = fs.readFileSync(filePath);
  assert.ok(finalContent.equals(contentA) || finalContent.equals(contentB));
  // Whichever write "won", its own reported hash/size must match the final file.
  const winner = finalContent.equals(contentA) ? resultA : resultB;
  assert.equal(winner.sha256, crypto.createHash('sha256').update(finalContent).digest('hex'));
  assert.equal(winner.size, finalContent.length);

  assert.deepEqual(fs.readdirSync(dataDir), ['a.txt']);
});

test('concurrent writes to different paths do not interfere with each other', async () => {
  const dataDir = tempDataDir();
  const contentA = Buffer.from('content for a');
  const contentB = Buffer.from('content for b');

  await Promise.all([
    writeFileAtomic(path.join(dataDir, 'a.txt'), Readable.from([contentA])),
    writeFileAtomic(path.join(dataDir, 'b.txt'), Readable.from([contentB])),
  ]);

  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'a.txt')), contentA);
  assert.deepEqual(fs.readFileSync(path.join(dataDir, 'b.txt')), contentB);
  assert.deepEqual(fs.readdirSync(dataDir).sort(), ['a.txt', 'b.txt']);
});
