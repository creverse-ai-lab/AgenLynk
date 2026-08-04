// Truncates text to at most maxBytes of UTF-8 without splitting a multi-byte
// character. Length checks on JavaScript strings count code units, not bytes,
// so byte caps must go through here.
export function utf8ByteHead(text, maxBytes) {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.length <= maxBytes) return text;
  let end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
  return bytes.subarray(0, end).toString("utf8");
}

// Bounded tail accumulator for UTF-8 text: append cost is proportional to the
// new/evicted chunks, not the full accumulated size. A string is materialized
// only when read.
export class BoundedUtf8Text {
  constructor(maxBytes, { onTrim = null } = {}) {
    this.maxBytes = maxBytes;
    this.onTrim = onTrim;
    this.chunks = [];
    this.head = 0;
    this.totalBytes = 0;
    this.trimmedBytes = 0;
    this.pendingHighSurrogate = "";
    this.pendingBytes = 0;
  }

  append(text) {
    if (text == null || text === "") return;
    let value = this.pendingHighSurrogate + String(text);
    this.pendingHighSurrogate = "";
    this.pendingBytes = 0;
    const lastCodeUnit = value.charCodeAt(value.length - 1);
    if (lastCodeUnit >= 0xd800 && lastCodeUnit <= 0xdbff) {
      this.pendingHighSurrogate = value.at(-1);
      this.pendingBytes = Buffer.byteLength(this.pendingHighSurrogate, "utf8");
      value = value.slice(0, -1);
    }
    const chunk = Buffer.from(value, "utf8");
    if (chunk.length > 0) {
      this.chunks.push(chunk);
      this.totalBytes += chunk.length;
    }
    this.#trim();
  }

  reset(text = "") {
    this.chunks = [];
    this.head = 0;
    this.totalBytes = 0;
    this.trimmedBytes = 0;
    this.pendingHighSurrogate = "";
    this.pendingBytes = 0;
    this.append(text);
  }

  toString() {
    const liveChunks = this.chunks.length - this.head;
    if (liveChunks === 0) return "";
    if (liveChunks > 1) this.chunks = [Buffer.concat(this.chunks.slice(this.head), this.totalBytes)];
    else if (this.head > 0) this.chunks = [this.chunks[this.head]];
    this.head = 0;
    return this.chunks[0].toString("utf8");
  }

  #trim() {
    while (this.totalBytes + this.pendingBytes > this.maxBytes && this.head < this.chunks.length) {
      const front = this.chunks[this.head];
      const excess = this.totalBytes + this.pendingBytes - this.maxBytes;
      if (front.length <= excess) {
        this.onTrim?.(front);
        this.totalBytes -= front.length;
        this.trimmedBytes += front.length;
        this.head += 1;
        continue;
      }
      let start = excess;
      while (start < front.length && (front[start] & 0xc0) === 0x80) start += 1;
      this.onTrim?.(front.subarray(0, start));
      this.totalBytes -= start;
      this.trimmedBytes += start;
      this.chunks[this.head] = front.subarray(start);
    }
    if (this.head > 1024 && this.head * 2 > this.chunks.length) {
      this.chunks = this.chunks.slice(this.head);
      this.head = 0;
    }
    if (this.totalBytes + this.pendingBytes > this.maxBytes) {
      if (this.pendingHighSurrogate) this.onTrim?.(Buffer.from(this.pendingHighSurrogate, "utf8"));
      this.trimmedBytes += this.pendingBytes;
      this.pendingHighSurrogate = "";
      this.pendingBytes = 0;
    }
  }
}
