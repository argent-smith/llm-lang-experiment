import express, { Express, NextFunction, Request, Response } from "express";
import { ServerConfig } from "./config";
import {
  decodeKey,
  deleteBlob,
  getBlob,
  listBlobs,
  putBlob,
  validateKey,
} from "./blobs";

const BLOB_PATH_PREFIX = "/blobs/";

/**
 * Extracts and validates the {key} path parameter shared by all
 * /blobs/{key} routes, or null if it's malformed/unsafe. Centralized so
 * every endpoint that accepts a key applies exactly the same checks.
 */
function extractKey(req: Request): string | null {
  const rawTail = req.path.slice(BLOB_PATH_PREFIX.length);
  const key = decodeKey(rawTail);
  if (key === null || !validateKey(key)) return null;
  return key;
}

export function createApp(config: ServerConfig): Express {
  const app = express();

  app.get("/healthz", (_req, res) => {
    res.status(200).send("ok");
  });

  // Registered before the "/blobs" list route below: with non-strict
  // routing, "/blobs" also matches "/blobs/" (trailing slash, empty key),
  // so this key-validating route must get first refusal on that path or
  // an empty key would silently fall through to the list handler instead
  // of getting the 400 it deserves. `.*` (not `.+`) is what lets it claim
  // that empty-tail case at all.
  app.get(/^\/blobs\/.*/, (req, res) => {
    const key = extractKey(req);
    if (key === null) {
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

  app.get("/blobs", (_req, res) => {
    res.status(200).json(listBlobs(config.dataDir));
  });

  app.put(
    /^\/blobs\/.*/,
    express.raw({ type: () => true, limit: "1gb" }),
    (req, res) => {
      const key = extractKey(req);
      if (key === null) {
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

  app.delete(/^\/blobs\/.*/, (req, res) => {
    const key = extractKey(req);
    if (key === null) {
      res.status(400).end();
      return;
    }

    const deleted = deleteBlob(config.dataDir, key);
    res.status(deleted ? 204 : 404).end();
  });

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
