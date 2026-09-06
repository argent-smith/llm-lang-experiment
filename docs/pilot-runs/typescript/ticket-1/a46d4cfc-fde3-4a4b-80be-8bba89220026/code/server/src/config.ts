export interface ServerConfig {
  dataDir: string;
  port: number;
}

/**
 * Parses server configuration from CLI args, falling back to environment
 * variables. Flags take precedence over env vars. See SYNCBOX-SPEC.md,
 * section "CLI (обязательный контракт)".
 */
export function parseConfig(
  argv: string[],
  env: NodeJS.ProcessEnv
): ServerConfig {
  let dataDir: string | undefined;
  let port: number | undefined;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--data-dir") {
      i++;
      dataDir = argv[i];
    } else if (arg === "--port") {
      i++;
      port = Number(argv[i]);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (dataDir === undefined) {
    dataDir = env.SYNCBOX_DATA_DIR;
  }

  if (port === undefined) {
    const envPort = env.SYNCBOX_PORT;
    port = envPort !== undefined ? Number(envPort) : 8080;
  }

  if (!dataDir) {
    throw new Error(
      "--data-dir is required (or SYNCBOX_DATA_DIR environment variable)"
    );
  }

  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid port: ${String(port)}`);
  }

  return { dataDir, port };
}
