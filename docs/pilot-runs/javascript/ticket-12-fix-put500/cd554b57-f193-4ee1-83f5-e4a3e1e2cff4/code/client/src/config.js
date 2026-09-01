'use strict';

function parseArgs(argv) {
  const positional = [];
  let server;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--server') {
      if (i + 1 >= argv.length) {
        throw new Error('--server requires a value');
      }
      server = argv[++i];
    } else if (arg.startsWith('--')) {
      throw new Error(`unknown argument: ${arg}`);
    } else {
      positional.push(arg);
    }
  }

  return { server, positional };
}

function resolveConfig(argv, env) {
  const { server, positional } = parseArgs(argv);

  if (positional.length === 0) {
    throw new Error('missing required argument <dir>');
  }
  if (positional.length > 1) {
    throw new Error(`unexpected argument: ${positional[1]}`);
  }

  const serverUrl = server ?? env.SYNCBOX_SERVER;
  if (!serverUrl) {
    throw new Error('--server is required (or set SYNCBOX_SERVER)');
  }

  return { dir: positional[0], serverUrl };
}

module.exports = { parseArgs, resolveConfig };
