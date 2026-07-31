export function readNdjson(stream, {
  maxLineBytes = 32 * 1024 * 1024,
  onLine,
  onOverflow
} = {}) {
  let chunks = [];
  let bytes = 0;
  let closed = false;

  const handleData = (chunk) => {
    if (closed) return;
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    let start = 0;
    for (let index = 0; index < buffer.length; index += 1) {
      if (buffer[index] !== 0x0a) continue;
      if (!append(buffer.subarray(start, index))) return;
      emitLine();
      start = index + 1;
    }
    append(buffer.subarray(start));
  };

  function append(buffer) {
    if (buffer.length === 0) return true;
    if (bytes + buffer.length > maxLineBytes) {
      close();
      onOverflow?.(new Error(`NDJSON frame exceeds ${maxLineBytes} bytes`));
      return false;
    }
    chunks.push(buffer);
    bytes += buffer.length;
    return true;
  }

  function emitLine() {
    let line = chunks.length === 1 ? chunks[0] : Buffer.concat(chunks, bytes);
    if (line.at(-1) === 0x0d) line = line.subarray(0, -1);
    chunks = [];
    bytes = 0;
    if (line.length > 0) onLine?.(line.toString("utf8"));
  }

  function close() {
    if (closed) return;
    closed = true;
    chunks = [];
    bytes = 0;
    stream.off("data", handleData);
  }

  stream.on("data", handleData);
  return { close };
}
