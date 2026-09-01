#!/usr/bin/env node
'use strict';

const fs = require('fs');
const { resolveConfig } = require('./config');
const { createServer } = require('./server');

function main() {
  let config;
  try {
    config = resolveConfig(process.argv.slice(2), process.env);
  } catch (err) {
    console.error(`syncbox-server: ${err.message}`);
    process.exit(1);
  }

  fs.mkdirSync(config.dataDir, { recursive: true });

  const server = createServer(config);

  server.on('error', (err) => {
    console.error(`syncbox-server: ${err.message}`);
    process.exit(1);
  });

  server.listen(config.port, () => {
    console.log(`syncbox-server listening on port ${config.port}, data dir ${config.dataDir}`);
  });

  const shutdown = () => {
    server.close(() => process.exit(0));
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main();
