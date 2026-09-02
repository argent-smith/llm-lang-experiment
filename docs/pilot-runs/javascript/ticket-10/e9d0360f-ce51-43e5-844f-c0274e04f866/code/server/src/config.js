'use strict';

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--data-dir') {
      args.dataDir = argv[++i];
    } else if (arg === '--port') {
      args.port = argv[++i];
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return args;
}

function resolveConfig(argv, env) {
  const args = parseArgs(argv);

  const dataDir = args.dataDir ?? env.SYNCBOX_DATA_DIR;
  if (!dataDir) {
    throw new Error('--data-dir is required (or set SYNCBOX_DATA_DIR)');
  }

  const portRaw = args.port ?? env.SYNCBOX_PORT ?? '8080';
  const port = Number(portRaw);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`invalid port: ${portRaw}`);
  }

  return { dataDir, port };
}

module.exports = { parseArgs, resolveConfig };
