import { closeSync, mkdirSync, openSync, readdirSync, statSync, unlinkSync, writeSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_MAX_FILE_BYTES = 100 * 1024 * 1024;
const DEFAULT_MAX_TOTAL_BYTES = 512 * 1024 * 1024;
const ARTIFACT_PREFIX = "acp-artifact-";

export function defaultArtifactRoot() {
  return process.env.ACP_GATEWAY_ARTIFACTS || join(homedir(), ".acp-gateway", "artifacts");
}

export class ArtifactStore {
  constructor({
    root = defaultArtifactRoot(),
    maxFileBytes = DEFAULT_MAX_FILE_BYTES,
    maxTotalBytes = DEFAULT_MAX_TOTAL_BYTES
  } = {}) {
    this.root = root;
    this.maxFileBytes = maxFileBytes;
    this.maxTotalBytes = maxTotalBytes;
    this.usedBytes = directoryBytes(root);
  }

  create(sessionId, kind) {
    return new ArtifactWriter(this, sessionId, kind);
  }

  /**
   * Two independent rules, either of which can remove an artifact:
   *   - age: older than `retentionMs`, unless still referenced (`keepPaths`),
   *   - session count: belongs to a session outside `keepSessionIds`, which is
   *     removed immediately regardless of age.
   * Time alone cannot bound a burst of activity inside the retention window,
   * and a count alone would keep one ancient session forever; together they do.
   */
  prune(retentionMs, now = Date.now(), keepPaths = null, keepSessionIds = null) {
    let removed = 0;
    for (const { path, size } of this.#prunable(retentionMs, now, keepPaths, keepSessionIds)) {
      try {
        unlinkSync(path);
        this.usedBytes = Math.max(0, this.usedBytes - size);
        removed += 1;
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
    }
    return removed;
  }

  /** How many artifacts `prune` would remove for the same arguments. */
  countPrunable(retentionMs, now = Date.now(), keepPaths = null, keepSessionIds = null) {
    let count = 0;
    for (const _ of this.#prunable(retentionMs, now, keepPaths, keepSessionIds)) count += 1;
    return count;
  }

  *#prunable(retentionMs, now, keepPaths, keepSessionIds) {
    if (retentionMs < 0 && !keepSessionIds) return;
    for (const entry of safeEntries(this.root)) {
      if (!entry.isFile() || !entry.name.startsWith(ARTIFACT_PREFIX)) continue;
      const path = join(this.root, entry.name);
      // The count rule overrides a live reference: once a session falls out of
      // the most-recent window its artifacts go, however recently written.
      const beyondSessionLimit = keepSessionIds != null && !belongsToSession(entry.name, keepSessionIds);
      if (!beyondSessionLimit && keepPaths?.has(path)) continue;
      let info;
      try {
        info = statSync(path);
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
        continue;
      }
      if (!beyondSessionLimit && (retentionMs < 0 || info.mtimeMs + retentionMs > now)) continue;
      yield { path, size: info.size };
    }
  }

  reserve(requested, fileBytes) {
    return Math.max(0, Math.min(
      requested,
      this.maxFileBytes - fileBytes,
      this.maxTotalBytes - this.usedBytes
    ));
  }
}

class ArtifactWriter {
  constructor(store, sessionId, kind) {
    this.store = store;
    this.sessionId = safeName(sessionId);
    this.kind = safeName(kind);
    this.path = null;
    this.fd = null;
    this.bytes = 0;
    this.truncated = false;
    this.complete = false;
    this.error = null;
  }

  get started() {
    return this.path != null;
  }

  get active() {
    return this.started || this.truncated || this.error != null;
  }

  append(value) {
    if (this.complete || this.error != null || value == null || value.length === 0) return;
    const buffer = Buffer.isBuffer(value) ? value : Buffer.from(String(value), "utf8");
    let accepted = this.store.reserve(buffer.length, this.bytes);
    if (accepted > 0 && accepted < buffer.length) {
      // Never end a truncated text artifact mid-character.
      while (accepted > 0 && (buffer[accepted] & 0xc0) === 0x80) accepted -= 1;
    }
    if (accepted <= 0) {
      this.truncated = true;
      return;
    }
    try {
      this.#open();
      let offset = 0;
      while (offset < accepted) {
        const written = writeSync(this.fd, buffer, offset, accepted - offset);
        if (written <= 0) throw new Error("Artifact write made no progress");
        offset += written;
        this.bytes += written;
        this.store.usedBytes += written;
      }
      if (accepted < buffer.length) this.truncated = true;
    } catch (error) {
      this.truncated = true;
      this.error = error?.message ?? String(error);
      this.#close();
    }
  }

  finalize(tail = null) {
    if (this.complete) return;
    if (this.started && tail != null) this.append(tail);
    this.#close();
    this.complete = true;
  }

  metadata() {
    if (!this.active) return null;
    return {
      path: this.path,
      bytes: this.bytes,
      complete: this.complete,
      truncated: this.truncated,
      ...(this.error ? { error: this.error } : {})
    };
  }

  #open() {
    if (this.fd != null) return;
    mkdirSync(this.store.root, { recursive: true, mode: 0o700 });
    const path = join(this.store.root, `${ARTIFACT_PREFIX}${this.sessionId}-${this.kind}-${randomUUID()}.txt`);
    this.fd = openSync(path, "wx", 0o600);
    this.path = path;
  }

  #close() {
    if (this.fd == null) return;
    try {
      closeSync(this.fd);
    } catch (error) {
      this.truncated = true;
      this.error ??= error?.message ?? String(error);
    }
    this.fd = null;
  }
}

// Artifacts are named `acp-artifact-<sessionId>-<kind>-<uuid>.txt`, and a
// session id contains dashes of its own, so membership is tested by prefix
// rather than by splitting the filename apart.
function belongsToSession(name, sessionIds) {
  for (const sessionId of sessionIds) {
    if (name.startsWith(`${ARTIFACT_PREFIX}${sessionId}-`)) return true;
  }
  return false;
}

function safeEntries(path) {
  try {
    return readdirSync(path, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

function directoryBytes(path) {
  let bytes = 0;
  for (const entry of safeEntries(path)) {
    if (!entry.isFile()) continue;
    try {
      bytes += statSync(join(path, entry.name)).size;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  return bytes;
}

function safeName(value) {
  return String(value ?? "artifact").replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 80) || "artifact";
}
