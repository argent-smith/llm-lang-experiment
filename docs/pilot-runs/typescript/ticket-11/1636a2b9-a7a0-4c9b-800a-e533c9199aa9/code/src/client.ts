import { ClientConfigError, parseClientConfig } from "./client-config.js";
import type { FileFailure, NetOptions } from "./net.js";
import { pull } from "./pull.js";
import { push } from "./push.js";
import { status } from "./status.js";
import { sync } from "./sync.js";

/** Runs the client CLI and returns the process exit code. */
export async function runClient(
  argv: string[],
  env: NodeJS.ProcessEnv,
  opts: NetOptions = {},
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
      return runPush(config.dir, config.server, opts);
    case "pull":
      return runPull(config.dir, config.server, opts);
    case "status":
      return runStatus(config.dir, config.server, opts);
    case "sync":
      return runSync(config.dir, config.server, opts);
  }
}

async function runPush(dir: string, server: string, opts: NetOptions): Promise<number> {
  try {
    const result = await push(dir, server, opts);
    for (const key of result.uploaded) {
      console.log(`uploaded ${key}`);
    }
    console.log(
      `push complete: ${result.uploaded.length} uploaded, ${result.skipped.length} unchanged`,
    );
    return reportFailuresAndExitCode("push", result.failed);
  } catch (err) {
    console.error(`syncbox: push failed: ${describeError(err)}`);
    return 1;
  }
}

async function runPull(dir: string, server: string, opts: NetOptions): Promise<number> {
  try {
    const result = await pull(dir, server, opts);
    for (const key of result.downloaded) {
      console.log(`downloaded ${key}`);
    }
    console.log(
      `pull complete: ${result.downloaded.length} downloaded, ${result.skipped.length} unchanged`,
    );
    return reportFailuresAndExitCode("pull", result.failed);
  } catch (err) {
    console.error(`syncbox: pull failed: ${describeError(err)}`);
    return 1;
  }
}

async function runSync(dir: string, server: string, opts: NetOptions): Promise<number> {
  try {
    const result = await sync(dir, server, opts);
    for (const key of result.uploaded) {
      console.log(`uploaded ${key}`);
    }
    for (const key of result.downloaded) {
      console.log(`downloaded ${key}`);
    }
    console.log(
      `sync complete: ${result.uploaded.length} uploaded, ${result.downloaded.length} downloaded, ${result.unchanged.length} unchanged`,
    );
    return reportFailuresAndExitCode("sync", result.failed);
  } catch (err) {
    console.error(`syncbox: sync failed: ${describeError(err)}`);
    return 1;
  }
}

async function runStatus(dir: string, server: string, opts: NetOptions): Promise<number> {
  try {
    const result = await status(dir, server, opts);
    for (const key of result.toUpload) {
      console.log(`would upload   ${key}`);
    }
    for (const key of result.toDownload) {
      console.log(`would download ${key}`);
    }
    console.log(
      `status complete: ${result.toUpload.length} to upload, ${result.toDownload.length} to download, ${result.unchanged.length} unchanged`,
    );
    return reportFailuresAndExitCode("status", result.failed);
  } catch (err) {
    console.error(`syncbox: status failed: ${describeError(err)}`);
    return 1;
  }
}

/**
 * Prints a per-file failure report to stderr for a partially-failed command
 * (some files succeeded, others didn't) and returns the resulting exit code
 * - non-zero whenever at least one file failed, even though the rest of the
 * command's work still completed.
 */
function reportFailuresAndExitCode(command: string, failed: FileFailure[]): number {
  if (failed.length === 0) {
    return 0;
  }
  for (const failure of failed) {
    console.error(`syncbox: ${command}: ${failure.key}: ${failure.message}`);
  }
  console.error(`syncbox: ${command}: ${failed.length} file(s) failed`);
  return 1;
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
