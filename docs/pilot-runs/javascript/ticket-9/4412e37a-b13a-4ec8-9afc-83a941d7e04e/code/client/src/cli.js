'use strict';

const { parseArgs } = require('./config');
const { push } = require('./push');
const { pull } = require('./pull');
const { status } = require('./status');

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2), process.env);
  } catch (err) {
    console.error(`syncbox: ${err.message}`);
    process.exitCode = 1;
    return;
  }

  if (args.command === 'push') {
    let result;
    try {
      result = await push({ dir: args.dir, server: args.server });
    } catch (err) {
      console.error(`syncbox: push failed: ${err.message}`);
      process.exitCode = 1;
      return;
    }

    for (const key of result.uploaded) console.log(`uploaded ${key}`);
    for (const key of result.skipped) console.log(`unchanged ${key}`);
    for (const failure of result.failed) console.error(`failed ${failure.key}: ${failure.error}`);
    console.log(
      `push: ${result.uploaded.length} uploaded, ${result.skipped.length} unchanged, ${result.failed.length} failed`
    );

    if (result.failed.length > 0) process.exitCode = 1;
    return;
  }

  if (args.command === 'pull') {
    let result;
    try {
      result = await pull({ dir: args.dir, server: args.server });
    } catch (err) {
      console.error(`syncbox: pull failed: ${err.message}`);
      process.exitCode = 1;
      return;
    }

    for (const key of result.downloaded) console.log(`downloaded ${key}`);
    for (const key of result.skipped) console.log(`unchanged ${key}`);
    for (const failure of result.failed) console.error(`failed ${failure.key}: ${failure.error}`);
    console.log(
      `pull: ${result.downloaded.length} downloaded, ${result.skipped.length} unchanged, ${result.failed.length} failed`
    );

    if (result.failed.length > 0) process.exitCode = 1;
    return;
  }

  if (args.command === 'status') {
    let result;
    try {
      result = await status({ dir: args.dir, server: args.server });
    } catch (err) {
      console.error(`syncbox: status failed: ${err.message}`);
      process.exitCode = 1;
      return;
    }

    for (const key of result.toUpload) console.log(`would upload ${key}`);
    for (const key of result.toDownload) console.log(`would download ${key}`);
    for (const key of result.unchanged) console.log(`unchanged ${key}`);
    console.log(
      `status: ${result.toUpload.length} would upload, ${result.toDownload.length} would download, ${result.unchanged.length} unchanged`
    );
    // Read-only comparison: exit 0 regardless of whether differences were
    // found. status reports them, it doesn't fix them (that's sync).
    return;
  }

  // sync lands in a future ticket (10); accept the command per the CLI
  // contract but fail clearly instead of doing nothing or crashing.
  console.error(`syncbox: command '${args.command}' is not implemented yet`);
  process.exitCode = 1;
}

main().catch((err) => {
  console.error(`syncbox: unexpected error: ${err.message}`);
  process.exitCode = 1;
});
