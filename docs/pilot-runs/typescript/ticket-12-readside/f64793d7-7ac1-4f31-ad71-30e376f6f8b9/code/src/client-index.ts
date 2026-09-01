import { runClient } from "./client.js";

runClient(process.argv.slice(2), process.env)
  .then((code) => process.exit(code))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
