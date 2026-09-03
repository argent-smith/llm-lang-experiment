import { ClientConfigError, parseClientConfig } from "./client-config.js";
import { pull } from "./pull.js";
import { push } from "./push.js";
import { status } from "./status.js";
import { sync } from "./sync.js";

/** Runs the client CLI and returns the process exit code. */
export async function runClient(
  argv: string[],
  env: NodeJS.ProcessEnv,
): Promise<number> {
  let config;
  try {
    config = parseClientConfig({ argv, env });
  } catch (err) {
    if (err instanceof ClientConfigError) {
      console.error(`syncbox: ${err.message}`);
      return 1;
    }
    throw err;
  }

  switch (config.command) {
    case "push":
      return runPush(config.dir, config.server);
    case "pull":
      return runPull(config.dir, config.server);
    case "status":
      return runStatus(config.dir, config.server);
    case "sync":
      return runSync(config.dir, config.server);
  }
}

async function runPush(dir: string, server: string): Promise<number> {
  try {
    const result = await push(dir, server);
    for (const key of result.uploaded) {
      console.log(`uploaded ${key}`);
    }
    console.log(
      `push complete: ${result.uploaded.length} uploaded, ${result.skipped.length} unchanged`,
    );
    return 0;
  } catch (err) {
    console.error(`syncbox: push failed: ${describeError(err)}`);
    return 1;
  }
}

async function runPull(dir: string, server: string): Promise<number> {
  try {
    const result = await pull(dir, server);
    for (const key of result.downloaded) {
      console.log(`downloaded ${key}`);
    }
    console.log(
      `pull complete: ${result.downloaded.length} downloaded, ${result.skipped.length} unchanged`,
    );
    return 0;
  } catch (err) {
    console.error(`syncbox: pull failed: ${describeError(err)}`);
    return 1;
  }
}

async function runSync(dir: string, server: string): Promise<number> {
  try {
    const result = await sync(dir, server);
    for (const key of result.uploaded) {
      console.log(`uploaded ${key}`);
    }
    for (const key of result.downloaded) {
      console.log(`downloaded ${key}`);
    }
    console.log(
      `sync complete: ${result.uploaded.length} uploaded, ${result.downloaded.length} downloaded, ${result.unchanged.length} unchanged`,
    );
    return 0;
  } catch (err) {
    console.error(`syncbox: sync failed: ${describeError(err)}`);
    return 1;
  }
}

async function runStatus(dir: string, server: string): Promise<number> {
  try {
    const result = await status(dir, server);
    for (const key of result.toUpload) {
      console.log(`would upload   ${key}`);
    }
    for (const key of result.toDownload) {
      console.log(`would download ${key}`);
    }
    console.log(
      `status complete: ${result.toUpload.length} to upload, ${result.toDownload.length} to download, ${result.unchanged.length} unchanged`,
    );
    return 0;
  } catch (err) {
    console.error(`syncbox: status failed: ${describeError(err)}`);
    return 1;
  }
}

function describeError(err: unknown): string {
  if (err instanceof Error) {
    const cause = (err as { cause?: unknown }).cause;
    if (cause instanceof Error) {
      return `${err.message}: ${cause.message}`;
    }
    return err.message;
  }
  return String(err);
}
