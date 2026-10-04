import { ClientError } from "./client.js";

/** A file that couldn't be processed, or a directory (key ending in `/`) that couldn't be read. */
export interface Failure {
  key: string;
  /** What went wrong, naming the file. */
  message: string;
}

/**
 * Records why `key` failed, so that the other files can still be processed.
 * Only a ClientError is such a failure; anything else is a bug and is rethrown.
 */
export function failure(key: string, err: unknown): Failure {
  if (err instanceof ClientError) return { key, message: err.message };
  throw err;
}

export interface TransferResult {
  failed: Failure[];
  /** Items left out at the end because the server had become unreachable. */
  notAttempted: number;
}

/**
 * Transfers the items one by one. One that fails is recorded, and the rest
 * are transferred all the same; only once the server can't be connected to
 * any more are the remaining ones left out, as they would fail alike.
 */
export async function transferEach<T>(
  items: readonly T[],
  keyOf: (item: T) => string,
  transfer: (item: T) => Promise<void>,
): Promise<TransferResult> {
  const failed: Failure[] = [];
  for (const [i, item] of items.entries()) {
    try {
      await transfer(item);
    } catch (err) {
      failed.push(failure(keyOf(item), err));
      if (err instanceof ClientError && err.unreachable) {
        return { failed, notAttempted: items.length - i - 1 };
      }
    }
  }
  return { failed, notAttempted: 0 };
}

/** The end of a summary line: how many files failed or weren't tried, if any. */
export function failureCounts({ failed, notAttempted }: TransferResult): string {
  return (failed.length > 0 ? `, ${failed.length} failed` : "") + (notAttempted > 0 ? `, ${notAttempted} not attempted` : "");
}

/** The report on what went wrong, for stderr: one line per failed file. Empty if nothing did. */
export function failureReport(command: string, { failed, notAttempted }: TransferResult): string[] {
  const lines: string[] = [];
  if (failed.length > 0) {
    lines.push(`syncbox: ${command}: ${failed.length} ${failed.length === 1 ? "file" : "files"} failed:`);
    lines.push(...failed.map(({ message }) => `  ${message}`));
  }
  if (notAttempted > 0) {
    lines.push(
      `syncbox: ${command}: stopped, the server became unreachable: ${notAttempted} more ${notAttempted === 1 ? "file was" : "files were"} not attempted`,
    );
  }
  return lines;
}

export function byKey(a: { key: string }, b: { key: string }): number {
  return a.key < b.key ? -1 : a.key > b.key ? 1 : 0;
}
