import express, { type Express } from "express";
import { getBlob, listBlobs, putBlob } from "./storage.js";

const BLOB_KEY_ROUTE = /^\/blobs\/(.+)$/;

export function createApp(dataDir: string): Express {
  const app = express();

  app.get("/healthz", (_req, res) => {
    res.sendStatus(200);
  });

  app.put(
    BLOB_KEY_ROUTE,
    express.raw({ type: () => true, limit: "1gb" }),
    async (req, res, next) => {
      try {
        const key = req.params[0];
        const body = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
        const { sha256, size } = await putBlob(dataDir, key, body);
        res.status(201).json({ key, sha256, size });
      } catch (err) {
        next(err);
      }
    },
  );

  app.get("/blobs", async (_req, res, next) => {
    try {
      const blobs = await listBlobs(dataDir);
      res.status(200).json(blobs);
    } catch (err) {
      next(err);
    }
  });

  app.get(BLOB_KEY_ROUTE, async (req, res, next) => {
    try {
      const key = req.params[0];
      const body = await getBlob(dataDir, key);
      if (body === undefined) {
        res.sendStatus(404);
        return;
      }
      res.status(200).type("application/octet-stream").send(body);
    } catch (err) {
      next(err);
    }
  });

  return app;
}
