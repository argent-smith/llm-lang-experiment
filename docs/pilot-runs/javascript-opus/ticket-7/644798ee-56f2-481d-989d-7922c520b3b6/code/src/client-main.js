#!/usr/bin/env node
// Entry point of the `syncbox` CLI: syncbox <command> <dir> --server <url>

import { ConfigError, USAGE, parseClientArgs } from './client-config.js';
import { RequestError, SyncboxClient } from './client.js';
import { push } from './push.js';

const EXIT_FAILURE = 1;
const EXIT_USAGE = 2;

async function main() {
  let config;
  try {
    config = parseClientArgs(process.argv.slice(2), process.env);
  } catch (err) {
    if (err instanceof ConfigError) {
      console.error(`syncbox: ${err.message}\n\n${USAGE}`);
      return EXIT_USAGE;
    }
    throw err;
  }

  if (config.help) {
    console.log(USAGE);
    return 0;
  }

  const client = new SyncboxClient(config.server);
  switch (config.command) {
    case 'push': {
      const { uploaded, upToDate } = await push({
        dir: config.dir,
        client,
        log: (line) => console.log(line),
        warn: (line) => console.error(`syncbox: ${line}`),
      });
      console.log(`push: ${uploaded.length} uploaded, ${upToDate.length} already up to date`);
      return 0;
    }
    default:
      console.error(`syncbox: the ${config.command} command is not implemented yet; only push is available`);
      return EXIT_FAILURE;
  }
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err) => {
    // Expected failures (server unreachable or refusing, unreadable files)
    // get their message only; anything else gets the stack too.
    const expected = err instanceof RequestError || typeof err?.code === 'string';
    console.error(`syncbox: ${expected ? err.message : err?.stack ?? err}`);
    process.exitCode = EXIT_FAILURE;
  },
);
