import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { ConfigError, DEFAULT_PORT, parseConfig } from "../src/config.js";

function config(argv: string[], env: NodeJS.ProcessEnv = {}) {
  const result = parseConfig(argv, env);
  assert.equal(result.kind, "config");
  return result.config;
}

describe("parseConfig", () => {
  it("reads --data-dir and --port flags", () => {
    assert.deepEqual(config(["--data-dir", "/srv/data", "--port", "9000"]), { dataDir: "/srv/data", port: 9000 });
  });

  it("accepts --flag=value form", () => {
    assert.deepEqual(config(["--data-dir=/srv/data", "--port=9000"]), { dataDir: "/srv/data", port: 9000 });
  });

  it("defaults port to 8080", () => {
    assert.equal(DEFAULT_PORT, 8080);
    assert.equal(config(["--data-dir", "/srv/data"]).port, 8080);
  });

  it("falls back to SYNCBOX_DATA_DIR and SYNCBOX_PORT", () => {
    assert.deepEqual(config([], { SYNCBOX_DATA_DIR: "/env/data", SYNCBOX_PORT: "7000" }), {
      dataDir: "/env/data",
      port: 7000,
    });
  });

  it("prefers flags over environment variables", () => {
    const env = { SYNCBOX_DATA_DIR: "/env/data", SYNCBOX_PORT: "7000" };
    assert.deepEqual(config(["--data-dir", "/flag/data", "--port", "9000"], env), {
      dataDir: "/flag/data",
      port: 9000,
    });
  });

  it("mixes flag and environment sources independently", () => {
    assert.deepEqual(config(["--port", "9000"], { SYNCBOX_DATA_DIR: "/env/data" }), {
      dataDir: "/env/data",
      port: 9000,
    });
  });

  it("treats empty environment variables as unset", () => {
    assert.equal(config(["--data-dir", "/d"], { SYNCBOX_PORT: "" }).port, 8080);
    assert.throws(() => parseConfig([], { SYNCBOX_DATA_DIR: "" }), ConfigError);
  });

  it("lets the last occurrence of a repeated flag win", () => {
    assert.equal(config(["--data-dir", "/a", "--data-dir", "/b"]).dataDir, "/b");
  });

  it("requires a data dir", () => {
    assert.throws(() => parseConfig([], {}), { name: "ConfigError", message: /--data-dir is required/ });
    assert.throws(() => parseConfig(["--port", "9000"], {}), ConfigError);
    assert.throws(() => parseConfig(["--data-dir="], {}), ConfigError);
  });

  it("rejects a flag with a missing value", () => {
    assert.throws(() => parseConfig(["--data-dir"], {}), { message: /--data-dir requires a value/ });
    assert.throws(() => parseConfig(["--data-dir", "/d", "--port"], {}), { message: /--port requires a value/ });
  });

  for (const bad of ["0", "65536", "-1", "abc", "80.5", " 80", "0x50", "1e3"]) {
    it(`rejects invalid port ${JSON.stringify(bad)}`, () => {
      assert.throws(() => parseConfig(["--data-dir", "/d", "--port", bad], {}), { message: /invalid port/ });
      assert.throws(() => parseConfig(["--data-dir", "/d"], { SYNCBOX_PORT: bad }), { message: /invalid port/ });
    });
  }

  it("accepts boundary ports", () => {
    assert.equal(config(["--data-dir", "/d", "--port", "1"]).port, 1);
    assert.equal(config(["--data-dir", "/d", "--port", "65535"]).port, 65535);
  });

  it("rejects unknown arguments", () => {
    assert.throws(() => parseConfig(["--data-dir", "/d", "--verbose"], {}), { message: /unknown argument: --verbose/ });
    assert.throws(() => parseConfig(["serve", "--data-dir", "/d"], {}), { message: /unknown argument: serve/ });
  });

  it("recognises --help", () => {
    assert.deepEqual(parseConfig(["--help"], {}), { kind: "help" });
    assert.deepEqual(parseConfig(["-h"], {}), { kind: "help" });
  });
});
