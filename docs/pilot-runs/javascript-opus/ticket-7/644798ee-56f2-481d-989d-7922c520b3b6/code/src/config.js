// Server configuration: command-line flags take precedence over environment
// variables (SYNCBOX_DATA_DIR / SYNCBOX_PORT), which take precedence over defaults.

export const DEFAULT_PORT = 8080;

export const USAGE = `Usage: syncbox-server --data-dir <path> [--port <n>]

Options:
  --data-dir <path>  Directory where blobs are stored (required).
                     Env: SYNCBOX_DATA_DIR
  --port <n>         TCP port to listen on, 1-65535 (default: ${DEFAULT_PORT}).
                     Env: SYNCBOX_PORT
  -h, --help         Show this help and exit.`;

export class ConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConfigError';
  }
}

const FLAGS = new Set(['--data-dir', '--port']);

/**
 * Parses server configuration.
 *
 * @param {string[]} argv  arguments without the node binary and script path
 * @param {Record<string, string | undefined>} env
 * @returns {{ help: true } | { help: false, dataDir: string, port: number }}
 * @throws {ConfigError} on missing or invalid values
 */
export function parseConfig(argv, env = {}) {
  const flags = {};

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === '-h' || arg === '--help') {
      return { help: true };
    }

    let name = arg;
    let value;
    const eq = arg.indexOf('=');
    if (arg.startsWith('--') && eq !== -1) {
      name = arg.slice(0, eq);
      value = arg.slice(eq + 1);
    }

    if (!FLAGS.has(name)) {
      throw new ConfigError(`unknown argument: ${arg}`);
    }

    if (value === undefined) {
      if (i + 1 >= argv.length) {
        throw new ConfigError(`${name} requires a value`);
      }
      value = argv[++i];
    }

    flags[name] = value;
  }

  const dataDir = pick(flags['--data-dir'], env.SYNCBOX_DATA_DIR);
  if (dataDir === undefined) {
    throw new ConfigError('data directory is required: pass --data-dir <path> or set SYNCBOX_DATA_DIR');
  }

  const rawPort = pick(flags['--port'], env.SYNCBOX_PORT);
  const port = rawPort === undefined ? DEFAULT_PORT : parsePort(rawPort);

  return { help: false, dataDir, port };
}

// Empty strings count as "not set" so that `SYNCBOX_PORT= run-server ...`
// falls through to the default instead of failing.
function pick(...candidates) {
  return candidates.find((v) => v !== undefined && v !== '');
}

function parsePort(raw) {
  if (!/^\d+$/.test(raw)) {
    throw new ConfigError(`invalid port: ${JSON.stringify(raw)} (expected an integer 1-65535)`);
  }
  const port = Number(raw);
  if (port < 1 || port > 65535) {
    throw new ConfigError(`invalid port: ${raw} (expected an integer 1-65535)`);
  }
  return port;
}
