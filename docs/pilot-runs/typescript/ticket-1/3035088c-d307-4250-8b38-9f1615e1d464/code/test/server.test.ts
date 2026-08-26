import assert from "node:assert/strict";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { createApp } from "../src/server.js";

test("GET /healthz returns 200", async () => {
  const server = createApp().listen(0);
  try {
    const { port } = server.address() as AddressInfo;
    const status = await new Promise<number | undefined>((resolve, reject) => {
      http
        .get(`http://127.0.0.1:${port}/healthz`, (res) => {
          res.resume();
          resolve(res.statusCode);
        })
        .on("error", reject);
    });
    assert.equal(status, 200);
  } finally {
    server.close();
  }
});
