#!/usr/bin/env node
// Entry point of the `syncbox` CLI: syncbox <command> <dir> --server <url>

import { ConfigError, USAGE, parseClientArgs } from './client-config.js';
import { RequestError, SyncboxClient } from './client.js';
import { LocalConflictError, pull } from './pull.js';
import { push } from './push.js';
import { formatStatus, status } from './status.js';

const EXIT_FAILURE = 1;
const EXIT_USAGE = 2;
// 128 + signal number, as a shell reports a process killed by the signal.
const EXIT_ON_SIGNAL = { SIGINT: 130, SIGTERM: 143 };

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
  const log = (line) => console.log(line);
  const warn = (line) => console.error(`syncbox: ${line}`);
  switch (config.command) {
    case 'push': {
      const { uploaded, upToDate } = await push({ dir: config.dir, client, log, warn });
      console.log(`push: ${uploaded.length} uploaded, ${upToDate.length} already up to date`);
      return 0;
    }
    case 'pull': {
      // pull writes into <dir>: on SIGINT/SIGTERM it stops and removes the
      // file it was downloading instead of leaving it half-written.
      const result = await interruptible((signal) => pull({ dir: config.dir, client, log, warn, signal }));
      if (typeof result === 'number') {
        return result;
      }
      console.log(`pull: ${result.downloaded.length} downloaded, ${result.upToDate.length} already up to date`);
      return 0;
    }
    case 'status': {
      // Read-only: lists what push and pull would transfer.
      const result = await status({ dir: config.dir, client, warn });
      for (const line of formatStatus(result)) {
        log(line);
      }
      return 0;
    }
    default:
      console.error(`syncbox: the ${config.command} command is not implemented yet; only push, pull and status are available`);
      return EXIT_FAILURE;
  }
}

/**
 * Runs `task` with a signal that is aborted on SIGINT or SIGTERM; a second
 * signal kills the process as usual.
 *
 * @template T
 * @param {(signal: AbortSignal) => Promise<T>} task
 * @returns {Promise<T | number>} what `task` returns, or the exit code if it was interrupted
 */
async function interruptible(task) {
  const controller = new AbortController();
  let exitCode;
  const handlers = Object.entries(EXIT_ON_SIGNAL).map(([name, code]) => {
    const handler = () => {
      exitCode = code;
      controller.abort();
    };
    process.once(name, handler);
    return [name, handler];
  });
  try {
    return await task(controller.signal);
  } catch (err) {
    if (controller.signal.aborted) {
      console.error('syncbox: interrupted');
      return exitCode;
    }
    throw err;
  } finally {
    for (const [name, handler] of handlers) {
      process.off(name, handler);
    }
  }
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err) => {
    // Expected failures (server unreachable or refusing, unreadable or
    // unwritable files) get their message only; anything else gets the stack too.
    const expected = err instanceof RequestError || err instanceof LocalConflictError || typeof err?.code === 'string';
    console.error(`syncbox: ${expected ? err.message : err?.stack ?? err}`);
    process.exitCode = EXIT_FAILURE;
  },
);
