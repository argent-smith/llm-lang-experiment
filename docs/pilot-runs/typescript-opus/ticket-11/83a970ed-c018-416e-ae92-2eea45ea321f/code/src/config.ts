export const DEFAULT_PORT = 8080;

export interface ServerConfig {
  dataDir: string;
  port: number;
}

export type ParseResult = { kind: "help" } | { kind: "config"; config: ServerConfig };

export class ConfigError extends Error {
  override name = "ConfigError";
}

export const USAGE = `Usage: syncbox-server --data-dir <path> [--port <n>]

Options:
  --data-dir <path>  Directory where blobs are stored (required).
                     Env: SYNCBOX_DATA_DIR
  --port <n>         TCP port to listen on (default ${DEFAULT_PORT}).
                     Env: SYNCBOX_PORT
  -h, --help         Show this help.

Command-line flags take precedence over environment variables.`;

/**
 * Resolves server configuration from command-line arguments and environment.
 * Precedence: flag > environment variable > default. Empty environment
 * variables are treated as unset.
 */
export function parseConfig(argv: readonly string[], env: NodeJS.ProcessEnv): ParseResult {
  let dataDir: string | undefined;
  let portRaw: string | undefined;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "-h" || arg === "--help") {
      return { kind: "help" };
    }

    const eq = arg.indexOf("=");
    const name = arg.startsWith("--") && eq !== -1 ? arg.slice(0, eq) : arg;
    let value: string | undefined;
    if (name === "--data-dir" || name === "--port") {
      if (eq !== -1 && arg.startsWith("--")) {
        value = arg.slice(eq + 1);
      } else {
        value = argv[++i];
        if (value === undefined) {
          throw new ConfigError(`${name} requires a value`);
        }
      }
    }

    switch (name) {
      case "--data-dir":
        dataDir = value;
        break;
      case "--port":
        portRaw = value;
        break;
      default:
        throw new ConfigError(`unknown argument: ${arg}`);
    }
  }

  dataDir ??= nonEmpty(env.SYNCBOX_DATA_DIR);
  portRaw ??= nonEmpty(env.SYNCBOX_PORT);

  if (dataDir === undefined || dataDir === "") {
    throw new ConfigError("--data-dir is required (or set SYNCBOX_DATA_DIR)");
  }

  const port = portRaw === undefined ? DEFAULT_PORT : parsePort(portRaw);
  return { kind: "config", config: { dataDir, port } };
}

function parsePort(raw: string): number {
  if (!/^[0-9]+$/.test(raw)) {
    throw new ConfigError(`invalid port: ${JSON.stringify(raw)} (expected an integer 1-65535)`);
  }
  const port = Number(raw);
  if (port < 1 || port > 65535) {
    throw new ConfigError(`invalid port: ${raw} (expected an integer 1-65535)`);
  }
  return port;
}

function nonEmpty(value: string | undefined): string | undefined {
  return value === undefined || value === "" ? undefined : value;
}
