export type ClientCommand = "push" | "pull" | "sync" | "status";

const COMMANDS: readonly ClientCommand[] = ["push", "pull", "sync", "status"];

export interface ClientConfig {
  command: ClientCommand;
  dir: string;
  server: string;
}

export interface ClientConfigSource {
  argv: string[];
  env: NodeJS.ProcessEnv;
}

export class ClientConfigError extends Error {}

export function parseClientConfig({ argv, env }: ClientConfigSource): ClientConfig {
  const [commandArg, dirArg, ...rest] = argv;

  if (commandArg === undefined) {
    throw new ClientConfigError(
      `command is required (one of: ${COMMANDS.join(", ")})`,
    );
  }
  if (!isClientCommand(commandArg)) {
    throw new ClientConfigError(
      `unknown command: ${commandArg} (expected one of: ${COMMANDS.join(", ")})`,
    );
  }
  if (dirArg === undefined) {
    throw new ClientConfigError("<dir> is required");
  }

  let server: string | undefined;
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (arg === "--server") {
      server = rest[++i];
    } else if (arg.startsWith("--server=")) {
      server = arg.slice("--server=".length);
    } else {
      throw new ClientConfigError(`unknown argument: ${arg}`);
    }
  }

  if (server === undefined) {
    server = env.SYNCBOX_SERVER;
  }
  if (!server) {
    throw new ClientConfigError(
      "--server is required (or set SYNCBOX_SERVER)",
    );
  }

  return {
    command: commandArg,
    dir: dirArg,
    server: server.replace(/\/+$/, ""),
  };
}

function isClientCommand(value: string): value is ClientCommand {
  return (COMMANDS as readonly string[]).includes(value);
}
