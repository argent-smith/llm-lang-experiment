// The `syncbox` CLI: syncbox <command> <dir> --server <url>. client-main.js
// runs it as a process; tests can run it in-process.

import { ConfigError, USAGE, parseClientArgs } from './client-config.js';
import { SyncboxClient } from './client.js';
import { failureCounts, formatFailures, isExpectedError } from './failures.js';
import { pull } from './pull.js';
import { push } from './push.js';
import { formatStatus, status } from './status.js';
import { stateDirectory } from './sync-state.js';
import { sync } from './sync.js';

// The spec only asks for a non-zero code on failure, without telling
// failures apart; so a server that cannot be reached and a run in which
// some files failed both exit with EXIT_FAILURE.
export const EXIT_FAILURE = 1;
export const EXIT_USAGE = 2;
// 128 + signal number, as a shell reports a process killed by the signal.
const EXIT_ON_SIGNAL = { SIGINT: 130, SIGTERM: 143 };

/**
 * Runs one command.
 *
 * @param {string[]} argv  arguments without the node binary and script path
 * @param {{
 *   env?: Record<string, string | undefined>,
 *   stdout?: (line: string) => void,
 *   stderr?: (line: string) => void,
 *   timeouts?: { connectTimeout?: number, responseTimeout?: number },  for SyncboxClient
 * }} [io]
 * @returns {Promise<number>} the exit code
 * @throws only on a bug; every failure the client expects is reported on
 *   `stderr` and gives EXIT_FAILURE
 */
export async function main(argv, { env = process.env, stdout = console.log, stderr = console.error, timeouts } = {}) {
  let config;
  try {
    config = parseClientArgs(argv, env);
  } catch (err) {
    if (err instanceof ConfigError) {
      stderr(`syncbox: ${err.message}\n\n${USAGE}`);
      return EXIT_USAGE;
    }
    throw err;
  }

  if (config.help) {
    stdout(USAGE);
    return 0;
  }

  try {
    return await run(config, { env, stdout, stderr, timeouts });
  } catch (err) {
    // The server unreachable or refusing before anything could be done, the
    // directory missing: a message is enough. Anything else is a bug.
    if (isExpectedError(err)) {
      stderr(`syncbox: ${err.message}`);
      return EXIT_FAILURE;
    }
    throw err;
  }
}

async function run(config, { env, stdout, stderr, timeouts }) {
  const client = new SyncboxClient(config.server, timeouts);
  const log = (line) => stdout(line);
  const warn = (line) => stderr(`syncbox: ${line}`);
  // What failed, after the summary; non-zero if anything did.
  const finish = (result) => {
    for (const line of formatFailures(config.command, result)) {
      stderr(line.startsWith(' ') ? line : `syncbox: ${line}`);
    }
    return result.failed.length > 0 || result.stopped ? EXIT_FAILURE : 0;
  };

  switch (config.command) {
    case 'push': {
      const result = await push({ dir: config.dir, client, log, warn });
      stdout(`push: ${result.uploaded.length} uploaded, ${result.upToDate.length} already up to date${failureCounts(result)}`);
      return finish(result);
    }
    case 'pull': {
      // pull writes into <dir>: on SIGINT/SIGTERM it stops and removes the
      // file it was downloading instead of leaving it half-written.
      const result = await interruptible(stderr, (signal) => pull({ dir: config.dir, client, log, warn, signal }));
      if (typeof result === 'number') {
        return result;
      }
      stdout(`pull: ${result.downloaded.length} downloaded, ${result.upToDate.length} already up to date${failureCounts(result)}`);
      return finish(result);
    }
    case 'status': {
      // Read-only: lists what push and pull would transfer.
      const result = await status({ dir: config.dir, client, warn });
      for (const line of formatStatus(result)) {
        log(line);
      }
      return finish(result);
    }
    case 'sync': {
      // Writes into <dir> like pull, so it is interruptible the same way.
      const stateDir = stateDirectory(env);
      const result = await interruptible(stderr, (signal) => sync({ dir: config.dir, client, stateDir, log, warn, signal }));
      if (typeof result === 'number') {
        return result;
      }
      const { uploaded, downloaded, upToDate, conflicts } = result;
      const resolved = conflicts.length > 0 ? `, ${conflicts.length} ${conflicts.length === 1 ? 'conflict' : 'conflicts'} resolved` : '';
      stdout(`sync: ${uploaded.length} uploaded, ${downloaded.length} downloaded, ${upToDate.length} already up to date${resolved}${failureCounts(result)}`);
      return finish(result);
    }
    default:
      throw new Error(`unhandled command: ${config.command}`);
  }
}

/**
 * Runs `task` with a signal that is aborted on SIGINT or SIGTERM; a second
 * signal kills the process as usual.
 *
 * @template T
 * @param {(line: string) => void} stderr
 * @param {(signal: AbortSignal) => Promise<T>} task
 * @returns {Promise<T | number>} what `task` returns, or the exit code if it was interrupted
 */
async function interruptible(stderr, task) {
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
      stderr('syncbox: interrupted');
      return exitCode;
    }
    throw err;
  } finally {
    for (const [name, handler] of handlers) {
      process.off(name, handler);
    }
  }
}
