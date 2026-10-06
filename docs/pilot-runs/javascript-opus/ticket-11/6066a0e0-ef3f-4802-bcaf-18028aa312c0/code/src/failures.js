// Partial failures: when one file of many fails, the commands record it and
// go on with the rest, then report what failed at the end.

import { RequestError, UnreachableError } from './client.js';

/** A blob that cannot be written because of what is already in the directory. */
export class LocalConflictError extends Error {
  /**
   * @param {string} key
   * @param {string} reason  e.g. "a directory is in the way"
   */
  constructor(key, reason) {
    super(`cannot write ${key}: ${reason}`);
    this.name = 'LocalConflictError';
    this.reason = reason;
  }
}

/**
 * Whether `err` is a failure the client expects and reports by its message
 * alone: the server unreachable or refusing, a local file that cannot be read
 * or written. Anything else is a bug.
 *
 * @param {unknown} err
 * @returns {boolean}
 */
export function isExpectedError(err) {
  return err instanceof RequestError || err instanceof LocalConflictError || typeof err?.code === 'string';
}

/**
 * The failures of one run of a command.
 *
 * Each file is processed through each(): if it fails in a way the client
 * expects, the failure is recorded and the next file is processed. If the
 * server cannot be reached at all any more, the remaining files are left
 * undone, since they would only fail the same way (each after a timeout,
 * perhaps); `stopped` says so.
 */
export class Failures {
  /** @type {Array<{ key: string, reason: string, error: Error }>} what failed and why, in order */
  files = [];

  /** @type {{ error: UnreachableError, remaining: number } | undefined} */
  stopped;

  /**
   * @param {string} key  the file's key; a directory's ends in "/"
   * @param {Error} error
   * @param {string} [action]  the transfer that failed: "upload" or "download"
   */
  add(key, error, action) {
    this.files.push({ key, reason: describe(error, action), error });
  }

  /**
   * Runs `step` for each item in turn, recording expected failures.
   *
   * @template {{ key: string }} T
   * @param {T[]} items
   * @param {string | ((item: T) => string | undefined) | undefined} action  for add()
   * @param {(item: T) => Promise<void>} step
   * @throws whatever `step` throws that is not an expected failure: an
   *   AbortError when interrupted, or a bug
   */
  async each(items, action, step) {
    for (let i = 0; i < items.length; i++) {
      if (this.stopped) {
        return;
      }
      try {
        await step(items[i]);
      } catch (err) {
        if (err instanceof UnreachableError) {
          this.stopped = { error: err, remaining: items.length - i };
          return;
        }
        if (err?.name === 'AbortError' || !isExpectedError(err)) {
          throw err;
        }
        this.add(items[i].key, err, typeof action === 'function' ? action(items[i]) : action);
      }
    }
  }

  /** For a command's result: `failed`, and `stopped` if set. */
  result() {
    return { failed: this.files, ...(this.stopped && { stopped: this.stopped }) };
  }
}

function describe(error, action) {
  if (error instanceof RequestError) {
    return action ? `${action} failed: ${error.reason}` : error.reason;
  }
  // A LocalConflictError's reason, or a system error, whose message names
  // the call and the path ("EACCES: permission denied, open '/sync/a.txt'").
  return error.reason ?? error.message;
}

/**
 * The end-of-run report on what failed, for stderr; empty if nothing did.
 *
 * @param {string} command  e.g. "push"
 * @param {{ failed?: Array<{ key: string, reason: string }>, stopped?: { error: Error, remaining: number } }} result
 * @returns {string[]} lines
 */
export function formatFailures(command, { failed = [], stopped }) {
  const lines = [];
  if (failed.length > 0) {
    lines.push(`${command}: ${failed.length} failed:`);
    for (const { key, reason } of failed) {
      lines.push(`  ${printable(key)}: ${reason}`);
    }
  }
  if (stopped) {
    lines.push(`${command} stopped, ${stopped.remaining} not attempted: ${stopped.error.message}`);
  }
  return lines;
}

/**
 * What the summary line adds about failures: ", 1 failed, 3 not attempted",
 * or nothing.
 *
 * @param {{ failed?: unknown[], stopped?: { remaining: number } }} result
 * @returns {string}
 */
export function failureCounts({ failed = [], stopped }) {
  return (failed.length > 0 ? `, ${failed.length} failed` : '') + (stopped ? `, ${stopped.remaining} not attempted` : '');
}

/** A key as is, or quoted if it holds characters that would garble a report (a newline, say). */
export function printable(key) {
  return /[\u0000-\u001f\u007f-\u009f]/.test(key) ? JSON.stringify(key) : key;
}
