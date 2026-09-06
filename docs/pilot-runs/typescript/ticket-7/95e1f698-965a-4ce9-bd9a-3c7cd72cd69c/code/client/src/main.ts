import { parseArgs } from "./config";
import { push } from "./push";

const NOT_YET_IMPLEMENTED = new Set(["pull", "sync", "status"]);

async function main(): Promise<void> {
  let config;
  try {
    config = parseArgs(process.argv.slice(2), process.env);
  } catch (err) {
    console.error(
      `syncbox: ${(err as Error).message}`,
      "\nusage: syncbox <push|pull|sync|status> <dir> --server <url>"
    );
    process.exitCode = 1;
    return;
  }

  if (NOT_YET_IMPLEMENTED.has(config.command)) {
    console.error(`syncbox: '${config.command}' is not implemented yet`);
    process.exitCode = 1;
    return;
  }

  try {
    const result = await push(config.dir, config.server);

    for (const key of result.uploaded) {
      console.log(`uploaded ${key}`);
    }
    for (const failure of result.failed) {
      console.error(`failed to upload ${failure.key}: ${failure.error}`);
    }
    console.log(
      `push complete: ${result.uploaded.length} uploaded, ` +
        `${result.skipped.length} unchanged, ${result.failed.length} failed`
    );

    if (result.failed.length > 0) {
      process.exitCode = 1;
    }
  } catch (err) {
    console.error(`syncbox: ${(err as Error).message}`);
    process.exitCode = 1;
  }
}

main();
