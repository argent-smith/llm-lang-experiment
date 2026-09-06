import * as crypto from "node:crypto";

export function sha256(content: Buffer): string {
  return crypto.createHash("sha256").update(content).digest("hex");
}
