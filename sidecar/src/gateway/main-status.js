// Gateway 1.9 reports where each Main stands (main_list, the main_status
// event): a Main asleep in agent_acp_wait is `waiting_tasks`, waiting on its
// Workers, neither on the person nor idle. While that lasts the monitor shows
// the Main's Frontdoor as "waiting_tasks" (the Pet's `awaiting`).
//
// Main status lives in the daemon's memory only and has no sequence: an event
// and a main_list reply can overtake each other, so per Main the higher
// revision wins, and a restarted daemon starts the list (and its revisions)
// over, so the book is reset whenever the daemon may be another one.

// A Main's key, as the daemon keys it: its session id and its front door's
// instance id.
function mainKey(caller) {
  return `${caller.sessionId ?? ""}\u0000${caller.instanceId}`;
}

// Gone Mains are remembered (by revision) so an older list entry that arrives
// after their going cannot bring them back; only this many are kept.
const MAX_GONE = 512;

export class MainStatusBook {
  #mains = new Map(); // key -> { caller, status, since, revision, taskIds, count, touched } | { gone, revision }
  // Counts main_list reads, so a reply can tell the entries an event touched
  // after it was asked for from those it alone speaks for.
  #epoch = 0;

  get size() {
    return this.#mains.size;
  }

  reset() {
    this.#mains.clear();
  }

  /**
   * One main_status event or main_list entry. Returns whether the set of
   * waiting Mains (or what one of them waits on) changed.
   */
  apply(entry) {
    const caller = entry?.caller;
    if (!caller || typeof caller.instanceId !== "string" || !caller.instanceId) return false;
    const revision = Number.isFinite(entry.revision) ? entry.revision : 0;
    const key = mainKey(caller);
    const previous = this.#mains.get(key);
    if (previous && revision <= previous.revision) return false;
    const wasWaiting = previous?.status === "waiting_tasks";
    if (entry.status === "gone") {
      this.#mains.set(key, { gone: true, revision });
      this.#pruneGone();
      return wasWaiting;
    }
    const taskIds = Array.isArray(entry.taskIds) ? entry.taskIds.filter((id) => typeof id === "string") : [];
    const next = {
      caller: {
        provider: typeof caller.provider === "string" ? caller.provider : null,
        sessionId: typeof caller.sessionId === "string" ? caller.sessionId : null,
        instanceId: caller.instanceId,
        // A Claude Main's process may hold another session by now; its pid
        // says which (currentCallerSession).
        pid: Number.isInteger(caller.pid) ? caller.pid : null
      },
      status: entry.status === "waiting_tasks" ? "waiting_tasks" : "active",
      since: typeof entry.since === "string" ? entry.since : null,
      revision,
      taskIds,
      count: Number.isFinite(entry.count) ? entry.count : taskIds.length,
      touched: this.#epoch
    };
    this.#mains.set(key, next);
    if (!wasWaiting && next.status !== "waiting_tasks") return false;
    return !wasWaiting || next.status !== "waiting_tasks"
      || previous.since !== next.since || previous.count !== next.count;
  }

  /** Call before sending main_list; pass what it returns to replace(). */
  beginList() {
    this.#epoch += 1;
    return this.#epoch;
  }

  /**
   * A main_list reply, merged by revision (the subscription came first). The
   * list names every Main connected when it was read, and a Main's going is
   * an event that is never replayed: one missing from it is gone, unless an
   * event touched it after the list was asked for (`epoch`).
   */
  replace(mains, epoch = null) {
    let changed = false;
    const listed = new Set();
    for (const entry of Array.isArray(mains) ? mains : []) {
      changed = this.apply(entry) || changed;
      if (entry?.caller?.instanceId) listed.add(mainKey(entry.caller));
    }
    if (epoch == null) return changed;
    for (const [key, entry] of this.#mains) {
      if (entry.gone || listed.has(key) || entry.touched >= epoch) continue;
      if (entry.status === "waiting_tasks") changed = true;
      this.#mains.delete(key);
    }
    return changed;
  }

  /** The Mains asleep on their tasks now. */
  waiting() {
    return [...this.#mains.values()].filter((entry) => entry.status === "waiting_tasks");
  }

  /** Every Main connected now, awake or asleep. */
  present() {
    return [...this.#mains.values()].filter((entry) => !entry.gone);
  }

  #pruneGone() {
    const gone = [...this.#mains].filter(([, entry]) => entry.gone);
    for (const [key] of gone.slice(0, Math.max(0, gone.length - MAX_GONE))) this.#mains.delete(key);
  }
}

/**
 * The monitor sessions with each waiting Main's Frontdoor shown as
 * "waiting_tasks". A Main with a session id is the local session
 * `local:<provider>:<id>` (as `currentCallerSession` maps a caller to the
 * session its process holds now); one without, or whose session the scan
 * does not list as a Frontdoor (an older Codex front door), is found through
 * its Workers' proven topology (`caller:<instanceId>`). A Frontdoor several
 * Mains map to waits only when none of them is awake. Only a Frontdoor whose
 * own record says it is in a turn is changed: the daemon keeps a heartbeat's
 * Main waiting for a grace after its wait answered, and a turn that ended by
 * then has ended.
 */
export function withMainStatus(sessions, mains, { workerTopology = null, currentCallerSession = null } = {}) {
  if (!mains.some((main) => main.status === "waiting_tasks")) return sessions;
  const frontdoors = new Map(sessions
    .filter((session) => session?.role === "frontdoor" && session.sessionId)
    .map((session) => [session.sessionId, session]));
  const frontdoorOf = (caller) => {
    const sessionId = currentCallerSession?.(caller) ?? caller.sessionId;
    const bySession = sessionId && caller.provider ? `local:${caller.provider}:${sessionId}` : null;
    if (bySession && frontdoors.has(bySession)) return bySession;
    const byTopology = workerTopology?.get(`caller:${caller.instanceId}`)?.parentSessionId ?? null;
    return byTopology && frontdoors.has(byTopology) ? byTopology : null;
  };
  const waitingOn = new Map();
  const awake = new Set();
  for (const main of mains) {
    const frontdoorId = frontdoorOf(main.caller);
    if (!frontdoorId) continue;
    if (main.status === "waiting_tasks") waitingOn.set(frontdoorId, main);
    else awake.add(frontdoorId);
  }
  for (const frontdoorId of awake) waitingOn.delete(frontdoorId);
  if (!waitingOn.size) return sessions;
  return sessions.map((session) => {
    const main = waitingOn.get(session?.sessionId);
    if (!main || session.role !== "frontdoor" || session.status !== "running") return session;
    return {
      ...session,
      status: "waiting_tasks",
      mainStatus: { status: main.status, since: main.since, taskIds: main.taskIds, count: main.count }
    };
  });
}
