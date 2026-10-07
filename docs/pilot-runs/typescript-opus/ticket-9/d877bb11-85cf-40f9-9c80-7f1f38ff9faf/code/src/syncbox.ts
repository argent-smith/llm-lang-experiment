import { CLIENT_USAGE, parseClientArgs, UsageError } from "./cli.js";
import { ClientError, SyncboxClient } from "./client.js";
import { pull } from "./pull.js";
import { push, type Reporter } from "./push.js";
import { formatStatus, status } from "./status.js";

const EXIT_FAILURE = 1;
const EXIT_USAGE = 2;

const reporter: Reporter = {
  info: (line) => console.log(line),
  warn: (line) => console.error(`syncbox: warning: ${line}`),
};

async function main(): Promise<number> {
  let parsed;
  try {
    parsed = parseClientArgs(process.argv.slice(2), process.env);
  } catch (err) {
    if (err instanceof UsageError) {
      console.error(`syncbox: ${err.message}\n\n${CLIENT_USAGE}`);
      return EXIT_USAGE;
    }
    throw err;
  }

  if (parsed.kind === "help") {
    console.log(CLIENT_USAGE);
    return 0;
  }

  const { command, dir, server } = parsed.config;
  if (command === "sync") {
    console.error(`syncbox: '${command}' is not implemented yet (only 'push', 'pull' and 'status' are available)`);
    return EXIT_FAILURE;
  }

  const client = new SyncboxClient(server);
  try {
    if (command === "push") {
      const summary = await push(dir, client, reporter);
      console.log(`push: ${summary.uploaded.length} uploaded, ${summary.unchanged.length} unchanged${skipped(summary.skipped)}`);
    } else if (command === "pull") {
      const summary = await pull(dir, client, reporter);
      console.log(`pull: ${summary.downloaded.length} downloaded, ${summary.unchanged.length} unchanged${skipped(summary.skipped)}`);
    } else {
      for (const line of formatStatus(await status(dir, client, reporter))) {
        console.log(line);
      }
    }
    return 0;
  } catch (err) {
    if (err instanceof ClientError) {
      console.error(`syncbox: ${command} failed: ${err.message}`);
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

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    console.error("syncbox: fatal error:", err);
    process.exit(EXIT_FAILURE);
  },
);
