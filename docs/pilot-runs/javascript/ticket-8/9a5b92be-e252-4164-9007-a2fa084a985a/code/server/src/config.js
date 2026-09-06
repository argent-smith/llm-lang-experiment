'use strict';

function parseConfig(argv, env) {
  let dataDir = env.SYNCBOX_DATA_DIR;
  let port = env.SYNCBOX_PORT !== undefined ? env.SYNCBOX_PORT : 8080;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--data-dir') {
      dataDir = argv[i + 1];
      i++;
    } else if (arg === '--port') {
      port = argv[i + 1];
      i++;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (!dataDir) {
    throw new Error('--data-dir is required (or set SYNCBOX_DATA_DIR)');
  }

  const portNum = Number(port);
  if (!Number.isInteger(portNum) || portNum <= 0 || portNum > 65535) {
    throw new Error(`invalid port: ${port}`);
  }

  return { dataDir, port: portNum };
}

module.exports = { parseConfig };
