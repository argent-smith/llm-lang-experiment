'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { resolveBlobPath } = require('../src/safe-path');

const dataDir = '/data';

test('resolves a simple key relative to dataDir', () => {
  const resolved = resolveBlobPath(dataDir, 'greeting.txt');
  assert.deepEqual(resolved, { key: 'greeting.txt', filePath: path.resolve('/data/greeting.txt') });
});

test('resolves a nested key relative to dataDir', () => {
  const resolved = resolveBlobPath(dataDir, 'docs%2Freadme.txt'.replace('%2F', '/'));
  assert.equal(resolved.filePath, path.resolve('/data/docs/readme.txt'));
});

test('decodes percent-encoded segments', () => {
  const resolved = resolveBlobPath(dataDir, 'a%20b.txt');
  assert.equal(resolved.key, 'a b.txt');
});

test('rejects a bare ".." key', () => {
  assert.equal(resolveBlobPath(dataDir, '..'), null);
});

test('rejects a key that escapes the root via a middle ".." segment', () => {
  assert.equal(resolveBlobPath(dataDir, 'docs/../../etc/passwd'), null);
});

test('rejects a key with a ".." segment even when it nets back inside the root', () => {
  assert.equal(resolveBlobPath(dataDir, 'docs/../secret.txt'), null);
});

test('rejects percent-encoded ".." segments', () => {
  assert.equal(resolveBlobPath(dataDir, '%2e%2e%2fetc%2fpasswd'), null);
  assert.equal(resolveBlobPath(dataDir, '%2e%2e'), null);
});

test('rejects an absolute POSIX path', () => {
  assert.equal(resolveBlobPath(dataDir, encodeURIComponent('/etc/passwd')), null);
});

test('rejects a leading-slash key produced by a double slash in the URL', () => {
  assert.equal(resolveBlobPath(dataDir, '/etc/passwd'), null);
});

test('rejects a key that resolves to the root itself', () => {
  assert.equal(resolveBlobPath(dataDir, '.'), null);
});

test('rejects malformed percent-encoding', () => {
  assert.equal(resolveBlobPath(dataDir, '%'), null);
  assert.equal(resolveBlobPath(dataDir, '%zz'), null);
  assert.equal(resolveBlobPath(dataDir, '%E2%82'), null);
});

test('rejects a key containing a NUL byte', () => {
  assert.equal(resolveBlobPath(dataDir, 'foo%00bar'), null);
});

test('allows a key that merely contains ".." as a substring, not a path segment', () => {
  const resolved = resolveBlobPath(dataDir, 'file..txt');
  assert.equal(resolved.key, 'file..txt');
  assert.equal(resolved.filePath, path.resolve('/data/file..txt'));
});

test('allows a key that is entirely dots but not a ".." segment', () => {
  const resolved = resolveBlobPath(dataDir, '...');
  assert.equal(resolved.key, '...');
});
