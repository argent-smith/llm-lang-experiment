import express, { type Express } from "express";

export function createApp(): Express {
  const app = express();

  app.get("/healthz", (_req, res) => {
    res.sendStatus(200);
  });

  return app;
}
