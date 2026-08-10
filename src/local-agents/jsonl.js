import { open } from "node:fs/promises";

const CHUNK_SIZE = 65_536;
const NEWLINE = 0x0A;
const CARRIAGE_RETURN = 0x0D;

export function readRecord(line) {
  try {
    const parsed = JSON.parse(line);
    return parsed === null || typeof parsed !== "object" ? parsed : parsed;
  } catch {
    return null;
  }
}

// Trims a single trailing \r so \r\n line endings parse like \n.
function decodeLine(buffer) {
  const end = buffer.length > 0 && buffer[buffer.length - 1] === CARRIAGE_RETURN
    ? buffer.length - 1
    : buffer.length;
  return buffer.subarray(0, end).toString("utf8");
}

/**
 * Yields parsed JSONL records from the end of a file backwards, reading fixed
 * chunks so a multi-gigabyte transcript costs only the tail.
 *
 * Line splitting happens on RAW BYTES and each line is decoded exactly once,
 * as a complete unit. Decoding a chunk before separating the carry-over would
 * corrupt any multibyte character that straddles a chunk boundary (replacing
 * its leading bytes with U+FFFD and silently dropping the record), and
 * re-encoding the carry-over per chunk would cost O(lineBytes²) on a single
 * line larger than one chunk. Unreadable files and unparseable lines are
 * skipped, matching the scanner's tolerance for transcripts another process
 * is still appending to.
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
    // Bytes after the earliest newline seen so far — the (possibly partial)
    // first line of everything already scanned. Carried as bytes, never
    // decoded until its true start is known.
    let remainder = Buffer.alloc(0);
    while (position > 0) {
      const size = Math.min(position, CHUNK_SIZE);
      position -= size;
      const buffer = Buffer.alloc(size);
      const { bytesRead } = await handle.read(buffer, 0, size, position);
      const window = Buffer.concat([buffer.subarray(0, bytesRead), remainder]);

      // Walk newlines backwards; everything before the earliest one carries
      // over to the next (earlier) chunk.
      let end = window.length;
      let newline = window.lastIndexOf(NEWLINE, end - 1);
      // A trailing newline terminates the last line rather than opening a new one.
      if (newline === end - 1) {
        end = newline;
        newline = end > 0 ? window.lastIndexOf(NEWLINE, end - 1) : -1;
      }
      while (newline >= 0) {
        const record = readRecord(decodeLine(window.subarray(newline + 1, end)));
        if (record && typeof record === "object") yield record;
        end = newline;
        newline = end > 0 ? window.lastIndexOf(NEWLINE, end - 1) : -1;
      }
      if (position > 0) {
        remainder = Buffer.from(window.subarray(0, end));
        // A single "line" spanning many chunks is not a transcript record this
        // scanner could use; growing the carry-over further only burns memory
        // and quadratic copies. Stop scanning older content instead.
        if (remainder.length > 8 * CHUNK_SIZE) return;
      } else if (end > 0) {
        // Start of file: the leading bytes are a complete line.
        const record = readRecord(decodeLine(window.subarray(0, end)));
        if (record && typeof record === "object") yield record;
      }
    }
  } catch {
    // A truncated or concurrently rotated transcript ends the scan quietly.
  } finally {
    await handle.close().catch(() => {});
  }
}
