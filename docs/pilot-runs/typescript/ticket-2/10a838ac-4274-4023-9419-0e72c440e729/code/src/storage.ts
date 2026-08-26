import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export interface PutResult {
  sha256: string;
  size: number;
}

export function keyToPath(dataDir: string, key: string): string {
  return join(dataDir, key);
}

export async function putBlob(
  dataDir: string,
  key: string,
  body: Buffer,
): Promise<PutResult> {
  const filePath = keyToPath(dataDir, key);
  await mkdir(dirname(filePath), { recursive: true });
  await writeFile(filePath, body);

  return {
    sha256: createHash("sha256").update(body).digest("hex"),
    size: body.length,
  };
}

export async function getBlob(
  dataDir: string,
  key: string,
): Promise<Buffer | undefined> {
  try {
    return await readFile(keyToPath(dataDir, key));
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      return undefined;
    }
    throw err;
  }
}
