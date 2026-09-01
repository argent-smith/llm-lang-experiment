import assert from "node:assert/strict";
import { test } from "node:test";
import { ClientConfigError, parseClientConfig } from "../src/client-config.js";

test("parses command, dir and --server", () => {
  const config = parseClientConfig({
    argv: ["push", "/tmp/x", "--server", "http://localhost:8080"],
    env: {},
  });
  assert.deepEqual(config, {
    command: "push",
    dir: "/tmp/x",
    server: "http://localhost:8080",
  });
});

test("supports --server=value syntax", () => {
  const config = parseClientConfig({
    argv: ["push", "/tmp/x", "--server=http://localhost:8080"],
    env: {},
  });
  assert.equal(config.server, "http://localhost:8080");
});

test("accepts pull, sync and status as commands", () => {
  for (const command of ["pull", "sync", "status"]) {
    const config = parseClientConfig({
      argv: [command, "/tmp/x", "--server", "http://localhost:8080"],
      env: {},
    });
    assert.equal(config.command, command);
  }
});

test("falls back to SYNCBOX_SERVER env var", () => {
  const config = parseClientConfig({
    argv: ["push", "/tmp/x"],
    env: { SYNCBOX_SERVER: "http://localhost:9999" },
  });
  assert.equal(config.server, "http://localhost:9999");
});

test("--server argv takes precedence over the env var", () => {
  const config = parseClientConfig({
    argv: ["push", "/tmp/x", "--server", "http://argv:1"],
    env: { SYNCBOX_SERVER: "http://env:2" },
  });
  assert.equal(config.server, "http://argv:1");
});

test("strips trailing slashes from --server", () => {
  const config = parseClientConfig({
    argv: ["push", "/tmp/x", "--server", "http://localhost:8080///"],
    env: {},
  });
  assert.equal(config.server, "http://localhost:8080");
});

test("throws ClientConfigError when the command is missing", () => {
  assert.throws(() => parseClientConfig({ argv: [], env: {} }), ClientConfigError);
});

test("throws ClientConfigError on an unknown command", () => {
  assert.throws(
    () => parseClientConfig({ argv: ["bogus", "/tmp/x"], env: {} }),
    ClientConfigError,
  );
});

test("throws ClientConfigError when <dir> is missing", () => {
  assert.throws(() => parseClientConfig({ argv: ["push"], env: {} }), ClientConfigError);
});

test("throws ClientConfigError when --server is missing everywhere", () => {
  assert.throws(
    () => parseClientConfig({ argv: ["push", "/tmp/x"], env: {} }),
    ClientConfigError,
  );
});

test("throws ClientConfigError on an unknown argument", () => {
  assert.throws(
    () =>
      parseClientConfig({
        argv: ["push", "/tmp/x", "--server", "http://x", "--bogus"],
        env: {},
      }),
    ClientConfigError,
  );
});
