// Provider-side ids of every session the Gateway ever reported, kept in
// ~/.acp-gateway/agenlynk/workers.json. Only ids (no content), independent of
// the history retention: a worker's transcript can outlive both its Gateway
// session and the monitor process, and must never come back as a Frontdoor.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { agenlynkHome } from "../hooks/endpoint.js";

const SAVE_DELAY_MS = 1_000;

export function defaultWorkerLedgerPath(env = process.env) {
  return join(agenlynkHome(env), "workers.json");
}

export function readWorkerLedger(path) {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    return Array.isArray(value?.ids) ? value.ids.filter((id) => typeof id === "string" && id) : [];
  } catch {
    return [];
  }
}

/** A debounced writer: call it with the current id set whenever it grows. */
export function workerLedgerWriter(path, delayMs = SAVE_DELAY_MS) {
  let timer = null;
  let latest = null;
  const flush = () => {
    timer = null;
    if (!latest) return;
    try {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      const temporary = `${path}.${process.pid}.tmp`;
      writeFileSync(temporary, `${JSON.stringify({ version: 1, ids: [...latest] })}\n`, { mode: 0o600 });
      renameSync(temporary, path);
    } catch (error) {
      console.error(`Worker ledger not saved: ${error.message}`);
    }
  };
  const write = (ids) => {
    latest = ids;
    if (timer) return;
    timer = setTimeout(flush, delayMs);
    timer.unref?.();
  };
  write.flush = () => {
    if (timer) clearTimeout(timer);
    flush();
  };
  return write;
}
