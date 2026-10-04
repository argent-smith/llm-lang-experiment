import { ConfigError, parseConfig, USAGE } from "./config.js";
import { startServer } from "./server.js";

const EXIT_USAGE = 2;

async function main(): Promise<number | undefined> {
  let parsed;
  try {
    parsed = parseConfig(process.argv.slice(2), process.env);
  } catch (err) {
    if (err instanceof ConfigError) {
      console.error(`syncbox-server: ${err.message}\n\n${USAGE}`);
      return EXIT_USAGE;
    }
    throw err;
  }

  if (parsed.kind === "help") {
    console.log(USAGE);
    return 0;
  }

  const { config } = parsed;
  let running;
  try {
    running = await startServer(config);
  } catch (err) {
    console.error(`syncbox-server: failed to start: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }

  console.log(`syncbox-server listening on port ${running.port}, data dir ${config.dataDir}`);

  // Node running as PID 1 in a container gets no default signal handlers,
  // so shutdown has to be wired up explicitly.
  const shutdown = (signal: NodeJS.Signals): void => {
    console.log(`syncbox-server: received ${signal}, shutting down`);
    running.close().then(
      () => process.exit(0),
      (err: unknown) => {
        console.error("syncbox-server: error during shutdown:", err);
        process.exit(1);
      },
    );
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
  return undefined;
}

main().then(
  (code) => {
    if (code !== undefined) process.exitCode = code;
  },
  (err: unknown) => {
    console.error("syncbox-server: fatal error:", err);
    process.exit(1);
  },
);
