import { parseArgs } from "./config";
import { pull } from "./pull";
import { push } from "./push";

const NOT_YET_IMPLEMENTED = new Set(["sync", "status"]);

async function runPush(dir: string, server: string): Promise<void> {
  const result = await push(dir, server);

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
}

async function runPull(dir: string, server: string): Promise<void> {
  const result = await pull(dir, server);

  for (const key of result.downloaded) {
    console.log(`downloaded ${key}`);
  }
  for (const failure of result.failed) {
    console.error(`failed to download ${failure.key}: ${failure.error}`);
  }
  console.log(
    `pull complete: ${result.downloaded.length} downloaded, ` +
      `${result.skipped.length} unchanged, ${result.failed.length} failed`
  );

  if (result.failed.length > 0) {
    process.exitCode = 1;
  }
}

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
    if (config.command === "push") {
      await runPush(config.dir, config.server);
    } else if (config.command === "pull") {
      await runPull(config.dir, config.server);
    }
  } catch (err) {
    console.error(`syncbox: ${(err as Error).message}`);
    process.exitCode = 1;
  }
}

main();
