import * as net from "node:net";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import { encodeKeyPath, listRemoteBlobs } from "../src/httpClient";

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

describe("network failure reporting", () => {
  it("names the cause when the connection is refused", async () => {
    // Grab a free port and close it right away so nothing is listening.
    const probe = net.createServer();
    await new Promise<void>((resolve) => probe.listen(0, resolve));
    const port = (probe.address() as AddressInfo).port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));

    await expect(listRemoteBlobs(`http://127.0.0.1:${port}`)).rejects.toThrow(
      /refused/i
    );
  });

  it("times out instead of hanging forever when the server accepts but never responds", async () => {
    // Track accepted sockets so the server can close promptly afterwards —
    // an aborted fetch abandons the socket client-side without necessarily
    // tearing down the TCP connection, which would otherwise leave
    // server.close() waiting forever for it to end.
    const sockets: net.Socket[] = [];
    const hung = net.createServer((socket) => {
      sockets.push(socket);
    });
    await new Promise<void>((resolve) => hung.listen(0, resolve));
    const port = (hung.address() as AddressInfo).port;

    const start = Date.now();
    await expect(listRemoteBlobs(`http://127.0.0.1:${port}`)).rejects.toThrow(
      /timed out/i
    );
    expect(Date.now() - start).toBeLessThan(15_000);

    sockets.forEach((s) => s.destroy());
    await new Promise<void>((resolve) => hung.close(() => resolve()));
  }, 20_000);
});
