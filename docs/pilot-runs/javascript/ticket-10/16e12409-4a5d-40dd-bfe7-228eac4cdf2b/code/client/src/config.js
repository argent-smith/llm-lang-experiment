'use strict';

const VALID_COMMANDS = ['push', 'pull', 'sync', 'status'];

// argv is the CLI argument list after the executable name, e.g.
// ["push", "/some/dir", "--server", "http://host:8080"].
function parseArgs(argv, env) {
  const command = argv[0];
  if (!command || !VALID_COMMANDS.includes(command)) {
    throw new Error(
      `unknown command: ${command || '<none>'} (expected one of: ${VALID_COMMANDS.join(', ')})`
    );
  }

  const dir = argv[1];
  if (!dir) {
    throw new Error('<dir> is required');
  }

  let server = env.SYNCBOX_SERVER;
  const rest = argv.slice(2);
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--server') {
      server = rest[i + 1];
      i++;
    } else {
      throw new Error(`unknown argument: ${rest[i]}`);
    }
  }

  if (!server) {
    throw new Error('--server is required (or set SYNCBOX_SERVER)');
  }

  // Strip a trailing slash so callers can always do `${server}/blobs`
  // without risking a doubled slash.
  return { command, dir, server: server.replace(/\/+$/, '') };
}

module.exports = { parseArgs, VALID_COMMANDS };
