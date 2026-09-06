import express, { Express, NextFunction, Request, Response } from "express";
import { ServerConfig } from "./config";
import { decodeKey, getBlob, listBlobs, putBlob, validateKey } from "./blobs";

const BLOB_PATH_PREFIX = "/blobs/";

export function createApp(config: ServerConfig): Express {
  const app = express();

  app.get("/healthz", (_req, res) => {
    res.status(200).send("ok");
  });

  app.get("/blobs", (_req, res) => {
    res.status(200).json(listBlobs(config.dataDir));
  });

  app.get(/^\/blobs\/.+/, (req, res) => {
    const rawTail = req.path.slice(BLOB_PATH_PREFIX.length);
    const key = decodeKey(rawTail);

    if (key === null || !validateKey(key)) {
      res.status(400).end();
      return;
    }

    const content = getBlob(config.dataDir, key);
    if (content === null) {
      res.status(404).end();
      return;
    }

    res.status(200).type("application/octet-stream").send(content);
  });

  app.put(
    /^\/blobs\/.*/,
    express.raw({ type: () => true, limit: "1gb" }),
    (req, res) => {
      const rawTail = req.path.slice(BLOB_PATH_PREFIX.length);
      const key = decodeKey(rawTail);

      if (key === null || !validateKey(key)) {
        res.status(400).end();
        return;
      }

      const content = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);

      try {
        const result = putBlob(config.dataDir, key, content);
        res.status(201).json(result);
      } catch {
        res.status(400).end();
      }
    }
  );

  // Safety net: the contract for these operations never allows a 5xx, so any
  // otherwise-uncaught error (e.g. from body parsing) degrades to 400 rather
  // than Express's default 500.
  app.use(
    (_err: unknown, _req: Request, res: Response, _next: NextFunction) => {
      res.status(400).end();
    }
  );

  return app;
}
