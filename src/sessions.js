import { randomUUID } from "node:crypto";
import { BoundedUtf8Text } from "./bounded-utf8.js";

const textAccumulators = new WeakMap();

export class SessionStore {
  constructor({ maxEvents = 200, maxTextBytes = 1_000_000, artifactStore = null, onChange = null, onEvent = null } = {}) {
    this.sessions = new Map();
    this.maxEvents = maxEvents;
    this.maxTextBytes = maxTextBytes;
    this.artifactStore = artifactStore;
    this.onChange = onChange;
    this.onEvent = onEvent;
  }

  create(fields) {
    const { resultText: initialResultText, thoughtText: initialThoughtText, ...rest } = fields;
    const session = {
      id: fields.id ?? `acp-${randomUUID()}`,
      status: "idle",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      events: [],
      turnId: null,
      stopReason: null,
      error: null,
      waiters: new Set(),
      eventSequence: 0,
      ...rest
    };
    let resultWriter = null;
    const resultBuffer = new BoundedUtf8Text(this.maxTextBytes, {
      onTrim: (buffer) => {
        resultWriter ??= this.artifactStore?.create(session.id, "result") ?? null;
        resultWriter?.append(buffer);
        session.resultArtifact = resultWriter?.metadata() ?? null;
      }
    });
    const thoughtBuffer = new BoundedUtf8Text(this.maxTextBytes);
    const segmentBuffer = new BoundedUtf8Text(this.maxTextBytes);
    if (initialResultText) resultBuffer.append(initialResultText);
    if (initialThoughtText) thoughtBuffer.append(initialThoughtText);
    textAccumulators.set(session, {
      resultBuffer,
      thoughtBuffer,
      segmentBuffer,
      inspection: [],
      get resultWriter() { return resultWriter; }
    });
    Object.defineProperties(session, {
      resultText: {
        enumerable: true,
        configurable: true,
        get: () => resultBuffer.toString(),
        set: (value) => {
          if (resultWriter?.started && !resultWriter.complete) resultWriter.finalize(resultBuffer.toString());
          resultWriter = null;
          session.resultArtifact = null;
          resultBuffer.reset(value);
          segmentBuffer.reset(value);
          textAccumulators.get(session).inspection.length = 0;
          session.resultFinalText = null;
          session.resultInspection = [];
        }
      },
      thoughtText: {
        enumerable: true,
        configurable: true,
        get: () => thoughtBuffer.toString(),
        set: (value) => thoughtBuffer.reset(value)
      }
    });
    session.eventSequence = Math.max(
      Number(session.eventSequence ?? 0),
      (session.events.at(-1)?.i ?? -1) + 1
    );
    this.sessions.set(session.id, session);
    this.onChange?.(session, null);
    return session;
  }

  appendResultText(session, text) {
    const state = textAccumulators.get(session);
    state?.resultBuffer.append(text);
    state?.segmentBuffer.append(text);
  }

  // Any non-message update (tool call, permission, plan, ...) closes the current
  // message segment: the text before it is narration, not the final answer.
  markSegmentBoundary(session, boundary) {
    const state = textAccumulators.get(session);
    if (!state) return;
    const text = state.segmentBuffer.toString();
    if (text.trim()) {
      state.inspection.push({
        text: text.length > 4000 ? text.slice(0, 4000).replace(/[\uD800-\uDBFF]$/, "") : text,
        bytes: Buffer.byteLength(text),
        truncated: text.length > 4000,
        boundary
      });
      if (state.inspection.length > 32) state.inspection.splice(0, state.inspection.length - 32);
    }
    state.segmentBuffer.reset("");
  }

  finalizeResult(session) {
    const state = textAccumulators.get(session);
    if (state) {
      const finalText = state.segmentBuffer.toString();
      session.resultFinalText = finalText.trim() ? finalText : state.resultBuffer.toString();
      session.resultInspection = [...state.inspection];
    }
    const writer = state?.resultWriter;
    if (!writer?.active) return null;
    writer.finalize(state.resultBuffer.toString());
    session.resultArtifact = writer.metadata();
    return session.resultArtifact;
  }

  appendThoughtText(session, text) {
    textAccumulators.get(session)?.thoughtBuffer.append(text);
  }

  get(id) {
    return this.sessions.get(id);
  }

  list() {
    return [...this.sessions.values()];
  }

  delete(id) {
    const deleted = this.sessions.delete(id);
    if (deleted) this.onChange?.(null, null);
    return deleted;
  }

  push(session, event) {
    const stored = { i: session.eventSequence++, ts: new Date().toISOString(), turnId: session.turnId, ...event };
    session.events.push(stored);
    if (session.events.length > this.maxEvents) {
      session.events.splice(0, session.events.length - this.maxEvents);
    }
    session.updatedAt = new Date().toISOString();
    for (const wake of session.waiters) wake();
    this.onEvent?.(session, stored);
    this.onChange?.(session, stored);
    return stored;
  }

  trimText(value) {
    const text = String(value ?? "");
    const bytes = Buffer.from(text);
    if (bytes.length <= this.maxTextBytes) return text;
    let start = bytes.length - this.maxTextBytes;
    while (start < bytes.length && (bytes[start] & 0xc0) === 0x80) start += 1;
    return bytes.subarray(start).toString("utf8");
  }

  checkpoints() {
    return this.list().map((session) => ({
      id: session.id,
      provider: session.provider,
      acpSessionId: session.acpSessionId,
      cwd: session.cwd,
      title: session.title ?? null,
      permissionPolicy: session.permissionPolicy,
      model: session.model ?? null,
      ownerRootId: session.ownerRootId,
      mcpServers: session.mcpServers ?? [],
      additionalDirectories: session.additionalDirectories ?? [],
      pinned: session.pinned === true,
      status: session.status,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      completedAt: session.completedAt ?? null,
      orphanedAt: session.orphanedAt ?? null,
      lastOwnerActivityAt: session.lastOwnerActivityAt ?? session.updatedAt,
      transientClearedAt: session.transientClearedAt ?? null,
      eventSequence: session.eventSequence,
      turnId: session.turnId ?? null,
      stopReason: session.stopReason ?? null
    }));
  }

  wait(session, waitMs) {
    return new Promise((done) => {
      const wake = () => {
        clearTimeout(timer);
        session.waiters.delete(wake);
        done();
      };
      const timer = setTimeout(wake, waitMs);
      session.waiters.add(wake);
    });
  }
}

export function publicSession(session) {
  return {
    sessionId: session.id,
    acpSessionId: session.acpSessionId,
    provider: session.provider,
    status: session.status,
    cwd: session.cwd,
    permissionPolicy: session.permissionPolicy,
    model: session.model ?? null,
    title: session.title,
    pinned: session.pinned === true,
    lastOwnerActivityAt: session.lastOwnerActivityAt ?? null,
    turnId: session.turnId,
    stopReason: session.stopReason,
    error: session.error,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    eventCount: session.events.length,
    resultArtifact: session.resultArtifact ?? null
  };
}
