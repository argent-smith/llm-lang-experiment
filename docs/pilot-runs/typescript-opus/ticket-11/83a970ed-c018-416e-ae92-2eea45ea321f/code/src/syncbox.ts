import { EXIT_FAILURE, runClient } from "./run-client.js";

const output = {
  out: (line: string) => console.log(line),
  err: (line: string) => console.error(line),
};

/**
 * Exits as soon as the output is written, rather than when the event loop
 * runs dry: a request given up on (a host name lookup that timed out, say)
 * may still keep it busy for a while.
 */
function exit(code: number): void {
  process.exitCode = code;
  process.stdout.write("", () => process.stderr.write("", () => process.exit()));
}

runClient(process.argv.slice(2), process.env, output).then(exit, (err: unknown) => {
  console.error("syncbox: fatal error:", err);
  exit(EXIT_FAILURE);
});
