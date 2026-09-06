'use strict';

const { parseArgs } = require('./config');
const { push } = require('./push');

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

  // pull/sync/status land in future tickets (8-10); accept the command per
  // the CLI contract but fail clearly instead of doing nothing or crashing.
  console.error(`syncbox: command '${args.command}' is not implemented yet`);
  process.exitCode = 1;
}

main().catch((err) => {
  console.error(`syncbox: unexpected error: ${err.message}`);
  process.exitCode = 1;
});
