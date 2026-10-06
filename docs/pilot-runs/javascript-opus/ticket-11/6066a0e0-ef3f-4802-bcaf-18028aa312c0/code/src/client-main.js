#!/usr/bin/env node
// Entry point of the `syncbox` CLI: syncbox <command> <dir> --server <url>

import { EXIT_FAILURE, main } from './cli.js';

// Once the command is done, the process is not kept waiting for anything it
// left behind: a host name lookup that timed out, say, cannot be cancelled
// and would otherwise hold the process until the resolver gives up.
const LINGER_MS = 1000;

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (err) => {
    // A bug: the stack helps.
    console.error(`syncbox: ${err?.stack ?? err}`);
    process.exitCode = EXIT_FAILURE;
  },
).finally(() => {
  // Unreferenced: fires only if something else still keeps the process up.
  setTimeout(() => process.exit(), LINGER_MS).unref();
});
