import { runCli } from "./cli";

runCli(process.argv.slice(2), process.env).then((code) => {
  process.exitCode = code;
});
