export interface ServerConfig {
  dataDir: string;
  port: number;
}

export interface ConfigSource {
  argv: string[];
  env: NodeJS.ProcessEnv;
}

export class ConfigError extends Error {}

export function parseConfig({ argv, env }: ConfigSource): ServerConfig {
  let dataDir: string | undefined;
  let port: number | undefined;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--data-dir") {
      dataDir = argv[++i];
    } else if (arg.startsWith("--data-dir=")) {
      dataDir = arg.slice("--data-dir=".length);
    } else if (arg === "--port") {
      port = parsePort(argv[++i]);
    } else if (arg.startsWith("--port=")) {
      port = parsePort(arg.slice("--port=".length));
    } else {
      throw new ConfigError(`unknown argument: ${arg}`);
    }
  }

  if (dataDir === undefined) {
    dataDir = env.SYNCBOX_DATA_DIR;
  }
  if (port === undefined && env.SYNCBOX_PORT !== undefined) {
    port = parsePort(env.SYNCBOX_PORT);
  }

  if (!dataDir) {
    throw new ConfigError(
      "--data-dir is required (or set SYNCBOX_DATA_DIR)",
    );
  }

  return { dataDir, port: port ?? 8080 };
}

function parsePort(raw: string | undefined): number {
  if (raw === undefined) {
    throw new ConfigError("--port requires a value");
  }
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0 || n > 65535) {
    throw new ConfigError(`invalid port: ${raw}`);
  }
  return n;
}
