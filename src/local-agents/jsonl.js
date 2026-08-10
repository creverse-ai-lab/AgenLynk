import { open } from "node:fs/promises";

const CHUNK_SIZE = 65_536;

export function readRecord(line) {
  try {
    const parsed = JSON.parse(line);
    return parsed === null || typeof parsed !== "object" ? parsed : parsed;
  } catch {
    return null;
  }
}

/**
 * Splits a buffer the way Python's `bytes.splitlines()` does: on \n, \r and
 * \r\n, with no trailing empty piece when the buffer ends in a newline.
 */
function splitLines(buffer) {
  const text = buffer.toString("utf8");
  const lines = text.split(/\r\n|\n|\r/);
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/**
 * Yields parsed JSONL records from the end of a file backwards, reading fixed
 * chunks so a multi-gigabyte transcript costs only the tail. Unreadable files
 * and unparseable lines are skipped, matching the watcher's tolerance for
 * transcripts that another process is still appending to.
 */
export async function* reversedRecords(path) {
  let handle;
  try {
    handle = await open(path, "r");
  } catch {
    return;
  }
  try {
    const stat = await handle.stat();
    let position = stat.size;
    let remainder = Buffer.alloc(0);
    while (position > 0) {
      const size = Math.min(position, CHUNK_SIZE);
      position -= size;
      const buffer = Buffer.alloc(size);
      await handle.read(buffer, 0, size, position);
      const lines = splitLines(Buffer.concat([buffer, remainder]));
      if (position > 0) {
        // The first line of this chunk may be the tail of a line that starts in
        // the previous chunk, so it is carried over instead of parsed.
        const head = lines.shift() ?? "";
        remainder = Buffer.from(head, "utf8");
      }
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const record = readRecord(lines[index]);
        if (record && typeof record === "object") yield record;
      }
    }
  } catch {
    // A truncated or concurrently rotated transcript ends the scan quietly.
  } finally {
    await handle.close().catch(() => {});
  }
}
