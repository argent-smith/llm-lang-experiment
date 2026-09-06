import { describe, it, expect } from "vitest";
import request from "supertest";
import { createApp } from "../src/app";

describe("GET /healthz", () => {
  it("returns 200", async () => {
    const app = createApp({ dataDir: "/tmp/syncbox-test-data", port: 8080 });
    const res = await request(app).get("/healthz");
    expect(res.status).toBe(200);
  });
});
