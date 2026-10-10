// Gateway 1.8 recommends rotating the Control token after an update
// (acp-gateway-bootstrap --rotate-token), and a daemon accepts only the
// identity it started with: a monitor still holding the old token is refused
// on every call. The monitor reads install.json once at start, so it watches
// the file and restarts (the app starts a new monitor, which reads the new
// identity) once the identity there is another one. The token itself is only
// compared, never logged.
import { readFileSync, watch } from "node:fs";
import { basename, dirname } from "node:path";

/** The identity install.json holds now, or null when it cannot be read. */
export function identityFrom(path) {
  try {
    const identity = JSON.parse(readFileSync(path, "utf8"))?.identity;
    return identity?.token && identity?.rootId ? { token: identity.token, rootId: identity.rootId } : null;
  } catch {
    return null;
  }
}

/** Whether install.json now names another identity than `current`. An unreadable file is no change. */
export function identityChanged(current, path) {
  const next = identityFrom(path);
  return Boolean(next && (next.token !== current.token || next.rootId !== current.rootId));
}

/**
 * Calls `onChange` once install.json names another identity. Watches the
 * directory (the installer replaces the file by rename); file events can come
 * late or not at all on a busy system, so `check` is also called when the
 * Gateway refuses the token. Returns `{ stop, check }`.
 */
export function watchIdentity(path, current, onChange, { delayMs = 500 } = {}) {
  let timer = null;
  let fired = false;
  let watcher = null;
  const check = () => {
    timer = null;
    if (fired || !identityChanged(current, path)) return;
    fired = true;
    onChange();
  };
  try {
    watcher = watch(dirname(path), { persistent: false }, (_event, filename) => {
      if (filename && filename !== basename(path)) return;
      if (timer) clearTimeout(timer);
      timer = setTimeout(check, delayMs);
      timer.unref?.();
    });
    watcher.on("error", () => {});
  } catch {
    // No directory to watch: a refused call still finds the change.
  }
  return {
    stop() {
      if (timer) clearTimeout(timer);
      watcher?.close();
    },
    check
  };
}
