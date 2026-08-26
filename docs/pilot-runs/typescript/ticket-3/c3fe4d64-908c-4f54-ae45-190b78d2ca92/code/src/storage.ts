import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, sep } from "node:path";

export interface PutResult {
  sha256: string;
  size: number;
}

export interface BlobMeta {
  key: string;
  size: number;
  sha256: string;
  modified_at: string;
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

export async function listBlobs(dataDir: string): Promise<BlobMeta[]> {
  const filePaths = await walkFiles(dataDir);
  const blobs = await Promise.all(
    filePaths.map(async (filePath) => {
      const [body, stats] = await Promise.all([
        readFile(filePath),
        stat(filePath),
      ]);
      return {
        key: toPosixKey(relative(dataDir, filePath)),
        size: stats.size,
        sha256: createHash("sha256").update(body).digest("hex"),
        modified_at: stats.mtime.toISOString(),
      };
    }),
  );

  blobs.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return blobs;
}

async function walkFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walkFiles(fullPath)));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }
  return files;
}

function toPosixKey(relativePath: string): string {
  return sep === "/" ? relativePath : relativePath.split(sep).join("/");
}
