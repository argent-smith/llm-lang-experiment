import express, { Express } from "express";
import { ServerConfig } from "./config";

export function createApp(_config: ServerConfig): Express {
  const app = express();

  app.get("/healthz", (_req, res) => {
    res.status(200).send("ok");
  });

  return app;
}
