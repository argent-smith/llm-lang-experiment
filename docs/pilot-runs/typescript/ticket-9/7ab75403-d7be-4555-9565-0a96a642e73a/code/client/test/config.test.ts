import { describe, expect, it } from "vitest";
import { parseArgs } from "../src/config";

describe("parseArgs", () => {
  it("parses <command> <dir> --server <url>", () => {
    const config = parseArgs(
      ["push", "/data", "--server", "http://localhost:8080"],
      {}
    );
    expect(config).toEqual({
      command: "push",
      dir: "/data",
      server: "http://localhost:8080",
    });
  });

  it("accepts --server before the dir", () => {
    const config = parseArgs(
      ["push", "--server", "http://localhost:8080", "/data"],
      {}
    );
    expect(config).toEqual({
      command: "push",
      dir: "/data",
      server: "http://localhost:8080",
    });
  });

  it("falls back to SYNCBOX_SERVER when --server is omitted", () => {
    const config = parseArgs(["push", "/data"], {
      SYNCBOX_SERVER: "http://env-server:9090",
    });
    expect(config.server).toBe("http://env-server:9090");
  });

  it("prefers the --server flag over the environment variable", () => {
    const config = parseArgs(
      ["push", "/data", "--server", "http://flag:8080"],
      { SYNCBOX_SERVER: "http://env:9090" }
    );
    expect(config.server).toBe("http://flag:8080");
  });

  it.each(["pull", "sync", "status"] as const)(
    "accepts the %s command",
    (command) => {
      const config = parseArgs(
        [command, "/data", "--server", "http://localhost:8080"],
        {}
      );
      expect(config.command).toBe(command);
    }
  );

  it("throws on an unknown command", () => {
    expect(() =>
      parseArgs(["bogus", "/data", "--server", "http://localhost:8080"], {})
    ).toThrow();
  });

  it("throws when no command is given", () => {
    expect(() => parseArgs([], {})).toThrow();
  });

  it("throws when <dir> is missing", () => {
    expect(() =>
      parseArgs(["push", "--server", "http://localhost:8080"], {})
    ).toThrow();
  });

  it("throws when --server is missing everywhere", () => {
    expect(() => parseArgs(["push", "/data"], {})).toThrow();
  });

  it("throws on an unexpected extra positional argument", () => {
    expect(() =>
      parseArgs(
        ["push", "/data", "extra", "--server", "http://localhost:8080"],
        {}
      )
    ).toThrow();
  });
});
