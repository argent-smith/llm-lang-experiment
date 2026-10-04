import { createHash, randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { access, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";

import { ClientError } from "./client.js";
import { type Reporter } from "./push.js";

/**
 * What sync last left identical on both sides: key → SHA-256. A file that
 * still has this content on one side hasn't changed there since.
 */
export type SyncBase = Map<string, string>;

const FORMAT_VERSION = 1;

interface StateFile {
  version: number;
  server: string;
  dir: string;
  files: Record<string, string>;
}

/**
 * Where sync keeps its state: `$XDG_STATE_HOME/syncbox`, by default
 * `~/.local/state/syncbox`. Outside the synced directory on purpose, so it
 * is never mistaken for one of its files.
 */
export function defaultStateDir(env: NodeJS.ProcessEnv): string {
  const xdg = env.XDG_STATE_HOME;
  // The XDG spec says relative paths are to be ignored.
  const base = xdg !== undefined && isAbsolute(xdg) ? xdg : join(homedir(), ".local", "state");
  return join(base, "syncbox");
}

/**
 * The state of one directory synced with one server: the same directory
 * synced with another server has a common state of its own with that one.
 */
export class SyncState {
  readonly path: string;

  constructor(
    stateDir: string,
    private readonly server: URL,
    /** Identifies the directory: its absolute path, unless the caller knows better. */
    private readonly dirId: string,
  ) {
    const name = createHash("sha256").update(`${server.href}\n${dirId}`).digest("hex");
    this.path = join(stateDir, `${name}.json`);
  }

  /**
   * The base left by the previous sync; empty on the first one. A state file
   * that can't be understood is ignored with a warning, as if there were none.
   * Also makes sure the state directory exists and is writable, so that sync
   * fails before transferring anything if it couldn't keep its state.
   */
  async load(reporter: Reporter): Promise<SyncBase> {
    const dir = dirname(this.path);
    try {
      await mkdir(dir, { recursive: true, mode: 0o700 });
      await access(dir, fsConstants.W_OK);
    } catch (err) {
      throw new ClientError(`cannot use sync state directory ${dir}: ${(err as Error).message}`);
    }
    let text;
    try {
      text = await readFile(this.path, "utf8");
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return new Map();
      throw new ClientError(`cannot read sync state ${this.path}: ${(err as Error).message}`);
    }
    const state = parseState(text);
    if (state === undefined || state.server !== this.server.href || state.dir !== this.dirId) {
      reporter.warn(`ignoring unusable sync state ${this.path}: every file that differs is treated as changed on both sides`);
      return new Map();
    }
    return new Map(Object.entries(state.files));
  }

  /** Replaces the stored base, atomically: a crash leaves either the old or the new one. */
  async save(base: SyncBase): Promise<void> {
    const state: StateFile = {
      version: FORMAT_VERSION,
      server: this.server.href,
      dir: this.dirId,
      files: Object.fromEntries([...base].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))),
    };
    const tmp = `${this.path}.${randomUUID()}.tmp`;
    try {
      await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
      await writeFile(tmp, `${JSON.stringify(state, null, 1)}\n`, { flag: "wx", mode: 0o600 });
      await rename(tmp, this.path);
    } catch (err) {
      await rm(tmp, { force: true });
      throw new ClientError(`cannot save sync state ${this.path}: ${(err as Error).message}`);
    }
  }
}

function parseState(text: string): StateFile | undefined {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (typeof value !== "object" || value === null) return undefined;
  const v = value as Record<string, unknown>;
  if (v.version !== FORMAT_VERSION || typeof v.server !== "string" || typeof v.dir !== "string") return undefined;
  const files = v.files;
  if (typeof files !== "object" || files === null || Array.isArray(files)) return undefined;
  if (!Object.values(files).every((sha) => typeof sha === "string")) return undefined;
  return v as unknown as StateFile;
}
