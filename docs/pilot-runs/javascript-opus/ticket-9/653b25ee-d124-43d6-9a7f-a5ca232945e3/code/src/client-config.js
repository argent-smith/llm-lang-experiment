// Client command line: syncbox <command> <dir> --server <url>.
// --server takes precedence over the SYNCBOX_SERVER environment variable.

export const COMMANDS = ['push', 'pull', 'status', 'sync'];

export const USAGE = `Usage: syncbox <command> <dir> --server <url>

Commands:
  push    Upload files from <dir> that are missing on the server or differ from it
  pull    Download files from the server that are missing in <dir> or differ from it
  status  Show what push/pull would transfer, changing nothing
  sync    Two-way sync between <dir> and the server (not implemented yet)

Options:
  --server <url>  Base URL of the Syncbox server, e.g. http://127.0.0.1:8080 (required).
                  Env: SYNCBOX_SERVER
  -h, --help      Show this help and exit.`;

export class ConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConfigError';
  }
}

/**
 * Parses client arguments.
 *
 * @param {string[]} argv  arguments without the node binary and script path
 * @param {Record<string, string | undefined>} env
 * @returns {{ help: true } | { help: false, command: string, dir: string, server: URL }}
 * @throws {ConfigError} on missing or invalid arguments
 */
export function parseClientArgs(argv, env = {}) {
  const positional = [];
  let server;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === '-h' || arg === '--help') {
      return { help: true };
    }
    if (arg === '--') {
      positional.push(...argv.slice(i + 1));
      break;
    }
    if (arg === '--server') {
      if (i + 1 >= argv.length) {
        throw new ConfigError('--server requires a value');
      }
      server = argv[++i];
      continue;
    }
    if (arg.startsWith('--server=')) {
      server = arg.slice('--server='.length);
      continue;
    }
    // A lone "-" is not an option, so it can name a directory.
    if (arg.startsWith('-') && arg !== '-') {
      throw new ConfigError(`unknown option: ${arg}`);
    }
    positional.push(arg);
  }

  const [command, dir, ...extra] = positional;
  if (command === undefined) {
    throw new ConfigError('a command is required');
  }
  if (!COMMANDS.includes(command)) {
    throw new ConfigError(`unknown command: ${command}`);
  }
  if (dir === undefined || dir === '') {
    throw new ConfigError(`${command} requires a directory`);
  }
  if (extra.length > 0) {
    throw new ConfigError(`unexpected argument: ${extra[0]}`);
  }

  // Empty strings count as "not set", as in the server's configuration.
  const rawServer = [server, env.SYNCBOX_SERVER].find((v) => v !== undefined && v !== '');
  if (rawServer === undefined) {
    throw new ConfigError('server URL is required: pass --server <url> or set SYNCBOX_SERVER');
  }

  return { help: false, command, dir, server: parseServerUrl(rawServer) };
}

function parseServerUrl(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new ConfigError(`invalid server URL: ${JSON.stringify(raw)} (expected e.g. http://127.0.0.1:8080)`);
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new ConfigError(`invalid server URL: ${JSON.stringify(raw)} (only http and https are supported)`);
  }
  if (url.search !== '' || url.hash !== '') {
    throw new ConfigError(`invalid server URL: ${JSON.stringify(raw)} (must not have a query or fragment)`);
  }
  return url;
}
