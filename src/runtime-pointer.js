// Read/write for the runtime root's pointer files (current.json,
// previous.json). Both name a runtime install and carry its identity; the
// installer and the updater each had their own reader and their own atomic
// writer for the same one-line format.

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

export const CURRENT_POINTER_FILE = "current.json";
export const PREVIOUS_POINTER_FILE = "previous.json";

/** Returns null for both "absent" and "not a valid pointer"; other IO errors throw. */
export async function readPointerFile(runtimeRoot, fileName) {
  try {
    const raw = JSON.parse(await readFile(join(runtimeRoot, fileName), "utf8"));
    if (raw?.formatVersion !== 1 || typeof raw.runtimeRoot !== "string" || !raw.runtimeRoot) return null;
    return raw;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

/** Writes the payload verbatim, atomically (temp file + rename). */
export async function writePointerFile(runtimeRoot, fileName, payload) {
  await mkdir(runtimeRoot, { recursive: true, mode: 0o700 });
  const temporary = join(runtimeRoot, `${fileName}.${process.pid}.tmp`);
  await writeFile(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, join(runtimeRoot, fileName));
}
