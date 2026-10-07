import { CLIENT_USAGE, parseClientArgs, UsageError } from "./cli.js";
import { ClientError, SyncboxClient, type ClientOptions } from "./client.js";
import { failureCounts, failureReport, type TransferResult } from "./failures.js";
import { pull } from "./pull.js";
import { push, type Reporter } from "./push.js";
import { defaultStateDir } from "./state.js";
import { formatStatus, status } from "./status.js";
import { formatSyncSummary, sync } from "./sync.js";

/** The command couldn't be carried out, or not for every file. */
export const EXIT_FAILURE = 1;
export const EXIT_USAGE = 2;

/** Where the client's output goes, one line at a time. */
export interface Output {
  out(line: string): void;
  err(line: string): void;
}

/**
 * Runs `syncbox <command> <dir> --server <url>` and returns its exit code:
 * 0 if everything was done, EXIT_FAILURE if the command failed as a whole
 * (server unreachable, say) or some files failed, EXIT_USAGE on bad
 * arguments. `clientOptions` is only for tests.
 */
export async function runClient(
  argv: readonly string[],
  env: NodeJS.ProcessEnv,
  output: Output,
  clientOptions: ClientOptions = {},
): Promise<number> {
  let parsed;
  try {
    parsed = parseClientArgs(argv, env);
  } catch (err) {
    if (err instanceof UsageError) {
      output.err(`syncbox: ${err.message}\n\n${CLIENT_USAGE}`);
      return EXIT_USAGE;
    }
    throw err;
  }

  if (parsed.kind === "help") {
    output.out(CLIENT_USAGE);
    return 0;
  }

  const { command, dir, server } = parsed.config;
  const reporter: Reporter = {
    info: (line) => output.out(line),
    warn: (line) => output.err(`syncbox: warning: ${line}`),
  };
  /** Reports the files that failed, if any; true if all went well. */
  const succeeded = (outcome: TransferResult): boolean => {
    for (const line of failureReport(command, outcome)) output.err(line);
    return outcome.failed.length === 0 && outcome.notAttempted === 0;
  };

  const client = new SyncboxClient(server, clientOptions);
  try {
    let ok;
    if (command === "push") {
      const summary = await push(dir, client, reporter);
      output.out(`push: ${summary.uploaded.length} uploaded, ${summary.unchanged.length} unchanged${skipped(summary.skipped)}${failureCounts(summary)}`);
      ok = succeeded(summary);
    } else if (command === "pull") {
      const summary = await pull(dir, client, reporter);
      output.out(`pull: ${summary.downloaded.length} downloaded, ${summary.unchanged.length} unchanged${skipped(summary.skipped)}${failureCounts(summary)}`);
      ok = succeeded(summary);
    } else if (command === "sync") {
      // SYNCBOX_STATE_ID: set by run-client, where <dir> is always the same
      // mount point inside the container, to the host directory it stands for.
      const options = { stateDir: defaultStateDir(env), dirId: env.SYNCBOX_STATE_ID || undefined };
      const summary = await sync(dir, client, reporter, options);
      output.out(formatSyncSummary(summary));
      ok = succeeded(summary);
      if (summary.stateError !== undefined) {
        output.err(`syncbox: sync: ${summary.stateError}`);
        ok = false;
      }
    } else {
      const report = await status(dir, client, reporter);
      for (const line of formatStatus(report)) output.out(line);
      ok = succeeded({ failed: report.failed, notAttempted: 0 });
    }
    return ok ? 0 : EXIT_FAILURE;
  } catch (err) {
    if (err instanceof ClientError) {
      output.err(`syncbox: ${command} failed: ${err.message}`);
      return EXIT_FAILURE;
    }
    throw err;
  } finally {
    client.close();
  }
}

function skipped(count: number): string {
  return count > 0 ? `, ${count} skipped` : "";
}
