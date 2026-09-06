import { describe, it, expect } from "vitest";
import { parseConfig } from "../src/config";

describe("parseConfig", () => {
  it("parses --data-dir and --port flags", () => {
    const config = parseConfig(
      ["--data-dir", "/tmp/data", "--port", "9090"],
      {}
    );
    expect(config).toEqual({ dataDir: "/tmp/data", port: 9090 });
  });

  it("defaults port to 8080 when not given", () => {
    const config = parseConfig(["--data-dir", "/tmp/data"], {});
    expect(config.port).toBe(8080);
  });

  it("falls back to SYNCBOX_DATA_DIR/SYNCBOX_PORT env vars", () => {
    const config = parseConfig([], {
      SYNCBOX_DATA_DIR: "/tmp/env-data",
      SYNCBOX_PORT: "9999",
    });
    expect(config).toEqual({ dataDir: "/tmp/env-data", port: 9999 });
  });

  it("prefers CLI flags over env vars", () => {
    const config = parseConfig(["--data-dir", "/tmp/flag"], {
      SYNCBOX_DATA_DIR: "/tmp/env",
      SYNCBOX_PORT: "1111",
    });
    expect(config.dataDir).toBe("/tmp/flag");
  });

  it("throws when --data-dir is missing everywhere", () => {
    expect(() => parseConfig([], {})).toThrow();
  });

  it("throws on a non-numeric port", () => {
    expect(() =>
      parseConfig(["--data-dir", "/tmp/data", "--port", "abc"], {})
    ).toThrow();
  });

  it("throws on an unknown flag", () => {
    expect(() =>
      parseConfig(["--data-dir", "/tmp/data", "--bogus"], {})
    ).toThrow();
  });
});
