import assert from "node:assert/strict";
import { test } from "node:test";
import { ConfigError, parseConfig } from "../src/config.js";

test("parses --data-dir and --port from argv", () => {
  const config = parseConfig({
    argv: ["--data-dir", "/tmp/x", "--port", "9090"],
    env: {},
  });
  assert.deepEqual(config, { dataDir: "/tmp/x", port: 9090 });
});

test("supports --flag=value syntax", () => {
  const config = parseConfig({
    argv: ["--data-dir=/tmp/x", "--port=9090"],
    env: {},
  });
  assert.deepEqual(config, { dataDir: "/tmp/x", port: 9090 });
});

test("defaults port to 8080 when not given", () => {
  const config = parseConfig({ argv: ["--data-dir", "/tmp/x"], env: {} });
  assert.equal(config.port, 8080);
});

test("falls back to SYNCBOX_DATA_DIR / SYNCBOX_PORT env vars", () => {
  const config = parseConfig({
    argv: [],
    env: { SYNCBOX_DATA_DIR: "/data", SYNCBOX_PORT: "9999" },
  });
  assert.deepEqual(config, { dataDir: "/data", port: 9999 });
});

test("argv flags take precedence over env vars", () => {
  const config = parseConfig({
    argv: ["--data-dir", "/argv-dir"],
    env: { SYNCBOX_DATA_DIR: "/env-dir", SYNCBOX_PORT: "1234" },
  });
  assert.equal(config.dataDir, "/argv-dir");
  assert.equal(config.port, 1234);
});

test("throws ConfigError when data-dir is missing", () => {
  assert.throws(() => parseConfig({ argv: [], env: {} }), ConfigError);
});

test("throws ConfigError on a non-numeric port", () => {
  assert.throws(
    () =>
      parseConfig({
        argv: ["--data-dir", "/tmp/x", "--port", "abc"],
        env: {},
      }),
    ConfigError,
  );
});

test("throws ConfigError on an out-of-range port", () => {
  assert.throws(
    () =>
      parseConfig({
        argv: ["--data-dir", "/tmp/x", "--port", "70000"],
        env: {},
      }),
    ConfigError,
  );
});

test("throws ConfigError on an unknown argument", () => {
  assert.throws(
    () => parseConfig({ argv: ["--bogus"], env: {} }),
    ConfigError,
  );
});
