import { parseArgs } from "./config";
import { pull } from "./pull";
import { push } from "./push";
import { status } from "./status";
import { sync } from "./sync";

async function runPush(dir: string, server: string): Promise<number> {
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

  return result.failed.length > 0 ? 1 : 0;
}

async function runPull(dir: string, server: string): Promise<number> {
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

  return result.failed.length > 0 ? 1 : 0;
}

async function runSync(dir: string, server: string): Promise<number> {
  const result = await sync(dir, server);

  for (const key of result.uploaded) {
    console.log(`uploaded ${key}`);
  }
  for (const key of result.downloaded) {
    console.log(`downloaded ${key}`);
  }
  for (const failure of result.failed) {
    console.error(`failed to sync ${failure.key}: ${failure.error}`);
  }
  console.log(
    `sync complete: ${result.uploaded.length} uploaded, ` +
      `${result.downloaded.length} downloaded, ` +
      `${result.unchanged.length} unchanged, ${result.failed.length} failed`
  );

  return result.failed.length > 0 ? 1 : 0;
}

async function runStatus(dir: string, server: string): Promise<number> {
  const result = await status(dir, server);

  for (const key of result.toUpload) {
    console.log(`would upload   ${key}`);
  }
  for (const key of result.toDownload) {
    console.log(`would download ${key}`);
  }
  for (const failure of result.failed) {
    console.error(`failed to read ${failure.key}: ${failure.error}`);
  }

  if (result.toUpload.length === 0 && result.toDownload.length === 0) {
    console.log(
      `status: no differences (${result.unchanged.length} unchanged)`
    );
  } else {
    console.log(
      `status: ${result.toUpload.length} to upload, ` +
        `${result.toDownload.length} to download, ` +
        `${result.unchanged.length} unchanged`
    );
  }

  return result.failed.length > 0 ? 1 : 0;
}

/**
 * Parses argv/env and runs the requested subcommand, printing progress to
 * console.log and errors to console.error. Returns the process exit code
 * rather than mutating process.exitCode directly, so it can be driven with
 * synthetic argv/env from tests without touching the real process.
 */
export async function runCli(
  argv: string[],
  env: NodeJS.ProcessEnv
): Promise<number> {
  let config;
  try {
    config = parseArgs(argv, env);
  } catch (err) {
    console.error(
      `syncbox: ${(err as Error).message}`,
      "\nusage: syncbox <push|pull|sync|status> <dir> --server <url>"
    );
    return 1;
  }

  try {
    if (config.command === "push") {
      return await runPush(config.dir, config.server);
    } else if (config.command === "pull") {
      return await runPull(config.dir, config.server);
    } else if (config.command === "sync") {
      return await runSync(config.dir, config.server);
    } else {
      return await runStatus(config.dir, config.server);
    }
  } catch (err) {
    console.error(`syncbox: ${(err as Error).message}`);
    return 1;
  }
}
