#!/usr/bin/env node
// Entry point: syncbox-server --data-dir <path> [--port <n>]
// Runs in the foreground until SIGINT/SIGTERM.

import fs from 'node:fs/promises';
import path from 'node:path';

import { ConfigError, USAGE, parseConfig } from './config.js';
import { createServer } from './server.js';

const EXIT_USAGE = 2;

async function main() {
  let config;
  try {
    config = parseConfig(process.argv.slice(2), process.env);
  } catch (err) {
    if (err instanceof ConfigError) {
      console.error(`syncbox-server: ${err.message}\n\n${USAGE}`);
      process.exit(EXIT_USAGE);
    }
    throw err;
  }

  if (config.help) {
    console.log(USAGE);
    return;
  }

  const dataDir = path.resolve(config.dataDir);
  try {
    await prepareDataDir(dataDir);
  } catch (err) {
    console.error(`syncbox-server: data directory ${dataDir} is not usable: ${err.message}`);
    process.exit(1);
  }

  const server = createServer({ dataDir });

  server.on('error', (err) => {
    console.error(`syncbox-server: cannot listen on port ${config.port}: ${err.message}`);
    process.exit(1);
  });

  server.listen(config.port, () => {
    console.log(`syncbox-server listening on port ${config.port}, data dir ${dataDir}`);
  });

  const shutdown = (signal) => {
    console.log(`syncbox-server: received ${signal}, shutting down`);
    server.close(() => process.exit(0));
    // Don't let idle keep-alive connections hold the process open.
    server.closeIdleConnections();
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

async function prepareDataDir(dir) {
  await fs.mkdir(dir, { recursive: true });
  const stat = await fs.stat(dir);
  if (!stat.isDirectory()) {
    throw new Error('not a directory');
  }
  await fs.access(dir, fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK);
}

main().catch((err) => {
  console.error('syncbox-server: fatal error:', err);
  process.exit(1);
});
