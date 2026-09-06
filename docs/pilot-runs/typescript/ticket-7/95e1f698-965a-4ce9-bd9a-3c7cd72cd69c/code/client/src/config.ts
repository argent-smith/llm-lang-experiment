export type Command = "push" | "pull" | "sync" | "status";

export interface ClientConfig {
  command: Command;
  dir: string;
  server: string;
}

const COMMANDS: Command[] = ["push", "pull", "sync", "status"];

function isCommand(value: string): value is Command {
  return (COMMANDS as string[]).includes(value);
}

/**
 * Parses CLI arguments shared by every subcommand: `<command> <dir>
 * --server <url>`, with --server falling back to SYNCBOX_SERVER. See
 * SYNCBOX-SPEC.md, section "CLI (обязательный контракт)".
 */
export function parseArgs(argv: string[], env: NodeJS.ProcessEnv): ClientConfig {
  const [rawCommand, ...rest] = argv;

  if (rawCommand === undefined || !isCommand(rawCommand)) {
    throw new Error(
      `expected a command (${COMMANDS.join("|")}), got: ${rawCommand ?? "<none>"}`
    );
  }

  let dir: string | undefined;
  let server: string | undefined;

  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (arg === "--server") {
      i++;
      server = rest[i];
    } else if (dir === undefined) {
      dir = arg;
    } else {
      throw new Error(`unexpected argument: ${arg}`);
    }
  }

  if (server === undefined) {
    server = env.SYNCBOX_SERVER;
  }

  if (!dir) {
    throw new Error("<dir> is required");
  }
  if (!server) {
    throw new Error(
      "--server is required (or SYNCBOX_SERVER environment variable)"
    );
  }

  return { command: rawCommand, dir, server };
}
