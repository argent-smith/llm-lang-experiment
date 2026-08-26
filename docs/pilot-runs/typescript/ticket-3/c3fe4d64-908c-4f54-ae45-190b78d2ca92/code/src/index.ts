import { mkdirSync } from "node:fs";
import { ConfigError, parseConfig } from "./config.js";
import { createApp } from "./server.js";

function main(): void {
  let config;
  try {
    config = parseConfig({ argv: process.argv.slice(2), env: process.env });
  } catch (err) {
    if (err instanceof ConfigError) {
      console.error(`syncbox: ${err.message}`);
      process.exit(1);
    }
    throw err;
  }

  mkdirSync(config.dataDir, { recursive: true });

  const app = createApp(config.dataDir);
  const server = app.listen(config.port, () => {
    console.log(
      `syncbox server listening on port ${config.port}, data dir ${config.dataDir}`,
    );
  });

  const shutdown = (): void => {
    server.close(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main();
