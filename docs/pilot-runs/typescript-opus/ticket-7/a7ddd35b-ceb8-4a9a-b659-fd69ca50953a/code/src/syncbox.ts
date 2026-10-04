import { CLIENT_USAGE, parseClientArgs, UsageError } from "./cli.js";
import { ClientError, SyncboxClient } from "./client.js";
import { push, type Reporter } from "./push.js";

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
  if (command !== "push") {
    console.error(`syncbox: '${command}' is not implemented yet (only 'push' is available)`);
    return EXIT_FAILURE;
  }

  const client = new SyncboxClient(server);
  try {
    const summary = await push(dir, client, reporter);
    const skipped = summary.skipped > 0 ? `, ${summary.skipped} skipped` : "";
    console.log(`push: ${summary.uploaded.length} uploaded, ${summary.unchanged.length} unchanged${skipped}`);
    return 0;
  } catch (err) {
    if (err instanceof ClientError) {
      console.error(`syncbox: push failed: ${err.message}`);
      return EXIT_FAILURE;
    }
    throw err;
  } finally {
    client.close();
  }
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
