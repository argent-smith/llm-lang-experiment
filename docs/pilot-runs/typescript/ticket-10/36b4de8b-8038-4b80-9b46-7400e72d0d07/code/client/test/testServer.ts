import * as crypto from "node:crypto";
import * as http from "node:http";
import type { AddressInfo } from "node:net";

export interface StoredBlob {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
  content: Buffer;
}

/**
 * A minimal in-memory stand-in for the real syncbox server, implementing
 * just enough of GET/PUT /blobs to exercise the client's push logic over a
 * real HTTP connection, without depending on the server package.
 */
export class TestServer {
  private readonly blobs = new Map<string, StoredBlob>();
  private readonly server: http.Server;
  url = "";

  constructor() {
    this.server = http.createServer((req, res) => this.handle(req, res));
  }

  async start(): Promise<void> {
    await new Promise<void>((resolve) => this.server.listen(0, resolve));
    const port = (this.server.address() as AddressInfo).port;
    this.url = `http://127.0.0.1:${port}`;
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  seed(key: string, content: Buffer, modifiedAt?: string): void {
    this.blobs.set(key, {
      key,
      size: content.length,
      sha256: crypto.createHash("sha256").update(content).digest("hex"),
      modified_at: modifiedAt ?? new Date().toISOString(),
      content,
    });
  }

  uploadedContent(key: string): Buffer | undefined {
    return this.blobs.get(key)?.content;
  }

  private handle(req: http.IncomingMessage, res: http.ServerResponse): void {
    const url = req.url ?? "";

    if (req.method === "GET" && url === "/blobs") {
      const list = [...this.blobs.values()].map(
        ({ key, size, sha256, modified_at }) => ({
          key,
          size,
          sha256,
          modified_at,
        })
      );
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(list));
      return;
    }

    if (req.method === "GET" && url.startsWith("/blobs/")) {
      const key = decodeURIComponent(url.slice("/blobs/".length));
      const blob = this.blobs.get(key);
      if (!blob) {
        res.writeHead(404);
        res.end();
        return;
      }
      res.writeHead(200, { "Content-Type": "application/octet-stream" });
      res.end(blob.content);
      return;
    }

    if (req.method === "PUT" && url.startsWith("/blobs/")) {
      const key = decodeURIComponent(url.slice("/blobs/".length));
      const chunks: Buffer[] = [];
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        const content = Buffer.concat(chunks);
        this.seed(key, content);
        res.writeHead(201, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            key,
            sha256: crypto.createHash("sha256").update(content).digest("hex"),
            size: content.length,
          })
        );
      });
      return;
    }

    res.writeHead(404);
    res.end();
  }
}
