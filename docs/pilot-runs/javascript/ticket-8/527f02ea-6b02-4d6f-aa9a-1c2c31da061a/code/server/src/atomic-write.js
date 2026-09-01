'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');
const { Transform } = require('stream');
const { pipeline } = require('stream/promises');

// Temp files live next to the target, named `<target>.<32 hex chars>.tmp`.
// The hex block is `crypto.randomBytes(16).toString('hex')`, so this pattern
// can't realistically collide with a real blob's filename.
const TEMP_SUFFIX_RE = /\.[0-9a-f]{32}\.tmp$/;

function isTempFileName(name) {
  return TEMP_SUFFIX_RE.test(name);
}

function tempPathFor(filePath) {
  return `${filePath}.${crypto.randomBytes(16).toString('hex')}.tmp`;
}

/**
 * Streams `source` into `filePath` atomically: written to a temp file in the
 * same directory (so the final rename is a same-filesystem, atomic
 * operation, not a cross-device copy) and renamed into place only once the
 * write has fully succeeded. A reader opening `filePath` at any point during
 * this therefore always sees either the complete old content or the
 * complete new content, never a partial write.
 *
 * On any failure - including `source` erroring or aborting mid-stream - the
 * temp file is removed and `filePath` is left untouched.
 */
async function writeFileAtomic(filePath, source) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });

  const tmpPath = tempPathFor(filePath);
  const hash = crypto.createHash('sha256');
  let size = 0;
  const hasher = new Transform({
    transform(chunk, _encoding, callback) {
      hash.update(chunk);
      size += chunk.length;
      callback(null, chunk);
    },
  });

  try {
    const out = fs.createWriteStream(tmpPath, { flags: 'wx' });
    await pipeline(source, hasher, out);
    await fsp.rename(tmpPath, filePath);
  } catch (err) {
    await fsp.rm(tmpPath, { force: true }).catch(() => {});
    throw err;
  }

  return { sha256: hash.digest('hex'), size };
}

module.exports = { writeFileAtomic, isTempFileName };
