import { open } from "node:fs/promises";

const CHUNK_SIZE = 65_536;
const NEWLINE = 0x0A;
const CARRIAGE_RETURN = 0x0D;

export function readRecord(line) {
  try {
    return JSON.parse(line);
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
export async function* reversedRecords(path, { maxBytes = Infinity } = {}) {
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
      // Budget reached: the older rest of the file is not read.
      if (position > 0 && stat.size - position >= maxBytes) return;
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

// Longest string a retained window record keeps. Twice the normalizers' body
// limit, so every event built from a slimmed record is identical to one
// built from the original: a record window only feeds those normalizers,
// and a multi-megabyte tool output would otherwise be held in full for as
// long as the window lasts.
export const RECORD_STRING_LIMIT = 16_000;
const MAX_SLIM_DEPTH = 32;

/**
 * `record` with every string longer than `limit` cut to it (the same "…" cut
 * the normalizers use). A string that holds JSON (Codex tool arguments) is
 * slimmed inside and re-serialized, so it still parses. Returns the record
 * itself when nothing was cut.
 */
export function slimRecord(record, limit = RECORD_STRING_LIMIT) {
  return slimValue(record, limit, 0);
}

function slimValue(value, limit, depth) {
  if (typeof value === "string") return value.length > limit ? slimString(value, limit, depth) : value;
  if (!value || typeof value !== "object" || depth >= MAX_SLIM_DEPTH) return value;
  if (Array.isArray(value)) {
    let copy = null;
    for (let index = 0; index < value.length; index += 1) {
      const next = slimValue(value[index], limit, depth + 1);
      if (next !== value[index]) {
        copy ??= value.slice();
        copy[index] = next;
      }
    }
    return copy ?? value;
  }
  let copy = null;
  for (const [key, item] of Object.entries(value)) {
    const next = slimValue(item, limit, depth + 1);
    if (next !== item) {
      copy ??= { ...value };
      copy[key] = next;
    }
  }
  return copy ?? value;
}

function slimString(text, limit, depth) {
  const first = text.trimStart()[0];
  if (first === "{" || first === "[") {
    try {
      const parsed = JSON.parse(text);
      if (parsed && typeof parsed === "object") return JSON.stringify(slimValue(parsed, limit, depth + 1));
    } catch {
      // Not JSON after all: cut as text.
    }
  }
  return `${text.slice(0, limit - 1)}…`;
}

/** Approximate retained size of a record: its line, or its slimmed JSON. */
export function recordSize(line, original, slimmed) {
  return slimmed === original ? line.length : JSON.stringify(slimmed).length;
}
