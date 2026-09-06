'use strict';

const fs = require('fs');
const { parseConfig } = require('./config');
const { createApp } = require('./app');

function main() {
  let config;
  try {
    config = parseConfig(process.argv.slice(2), process.env);
  } catch (err) {
    console.error(`syncbox-server: ${err.message}`);
    process.exit(1);
  }

  fs.mkdirSync(config.dataDir, { recursive: true });

  const app = createApp();
  app.listen(config.port, () => {
    console.log(`syncbox-server listening on port ${config.port}, data-dir ${config.dataDir}`);
  });
}

main();
