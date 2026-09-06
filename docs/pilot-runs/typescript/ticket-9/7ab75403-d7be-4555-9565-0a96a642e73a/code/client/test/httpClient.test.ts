import { describe, expect, it } from "vitest";
import { encodeKeyPath } from "../src/httpClient";

describe("encodeKeyPath", () => {
  it("leaves a simple ASCII key unchanged", () => {
    expect(encodeKeyPath("greeting.txt")).toBe("greeting.txt");
  });

  it("keeps the '/' between segments literal", () => {
    expect(encodeKeyPath("docs/readme.txt")).toBe("docs/readme.txt");
  });

  it("percent-encodes a space within a segment", () => {
    expect(encodeKeyPath("my notes.txt")).toBe("my%20notes.txt");
  });

  it("percent-encodes each segment independently for nested keys", () => {
    expect(encodeKeyPath("a b/c d.txt")).toBe("a%20b/c%20d.txt");
  });

  it("encodes a non-ASCII segment", () => {
    expect(encodeKeyPath("café.txt")).toBe(encodeURIComponent("café.txt"));
  });
});
