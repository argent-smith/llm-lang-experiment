import * as fs from "node:fs";
import { parseConfig } from "./config";
import { createApp } from "./app";

function main(): void {
  const config = parseConfig(process.argv.slice(2), process.env);
  fs.mkdirSync(config.dataDir, { recursive: true });

  const app = createApp(config);
  app.listen(config.port, () => {
    console.log(
      `syncbox server listening on port ${config.port}, data-dir=${config.dataDir}`
    );
  });
}

main();
