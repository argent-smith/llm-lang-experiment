export const COMMANDS = ["push", "pull", "status", "sync"] as const;
export type Command = (typeof COMMANDS)[number];

export interface ClientConfig {
  command: Command;
  dir: string;
  /** Base URL of the server, always with a trailing slash. */
  server: URL;
}

export type CliParseResult = { kind: "help" } | { kind: "command"; config: ClientConfig };

export class UsageError extends Error {
  override name = "UsageError";
}

export const CLIENT_USAGE = `Usage: syncbox <command> <dir> --server <url>

Commands:
  push    Upload files from <dir> that are missing on the server or differ from it
  pull    Download files from the server that are missing or differ locally
  status  Show what push/pull would transfer, without changing anything
  sync    Upload and download whatever differs, in the direction of the side
          that changed it since the last sync; if both did, the later
          modification time wins (the local version on a tie). Deletes nothing.

Options:
  --server <url>  Base URL of the Syncbox server, e.g. http://127.0.0.1:8080
                  (required). Env: SYNCBOX_SERVER
  -h, --help      Show this help.

The command-line flag takes precedence over the environment variable.
sync keeps what it last synced in $XDG_STATE_HOME/syncbox
(default ~/.local/state/syncbox), not in <dir>.`;

/**
 * Resolves the client invocation from command-line arguments and environment.
 * `--server` falls back to SYNCBOX_SERVER; an empty variable counts as unset.
 */
export function parseClientArgs(argv: readonly string[], env: NodeJS.ProcessEnv): CliParseResult {
  const positionals: string[] = [];
  let serverRaw: string | undefined;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "-h" || arg === "--help") {
      return { kind: "help" };
    }
    if (arg === "--server") {
      serverRaw = argv[++i];
      if (serverRaw === undefined) {
        throw new UsageError("--server requires a value");
      }
    } else if (arg.startsWith("--server=")) {
      serverRaw = arg.slice("--server=".length);
    } else if (arg.startsWith("-") && arg !== "-") {
      throw new UsageError(`unknown option: ${arg}`);
    } else {
      positionals.push(arg);
    }
  }

  const [command, dir, ...extra] = positionals;
  if (command === undefined) {
    throw new UsageError("missing command");
  }
  if (!isCommand(command)) {
    throw new UsageError(`unknown command: ${command}`);
  }
  if (dir === undefined || dir === "") {
    throw new UsageError(`${command}: missing <dir>`);
  }
  if (extra.length > 0) {
    throw new UsageError(`unexpected argument: ${extra[0]}`);
  }

  serverRaw ??= env.SYNCBOX_SERVER === "" ? undefined : env.SYNCBOX_SERVER;
  if (serverRaw === undefined || serverRaw === "") {
    throw new UsageError("--server is required (or set SYNCBOX_SERVER)");
  }

  return { kind: "command", config: { command, dir, server: parseServerUrl(serverRaw) } };
}

function isCommand(value: string): value is Command {
  return (COMMANDS as readonly string[]).includes(value);
}

/**
 * Accepts an http(s) URL, optionally with a path prefix the API is mounted
 * under (`http://host/syncbox` → `http://host/syncbox/blobs`).
 */
export function parseServerUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new UsageError(`invalid server URL: ${JSON.stringify(raw)} (expected e.g. http://127.0.0.1:8080)`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new UsageError(`invalid server URL: ${JSON.stringify(raw)} (only http:// and https:// are supported)`);
  }
  if (url.search !== "" || url.hash !== "") {
    throw new UsageError(`invalid server URL: ${JSON.stringify(raw)} (must not contain a query or fragment)`);
  }
  if (!url.pathname.endsWith("/")) {
    url.pathname += "/";
  }
  return url;
}
