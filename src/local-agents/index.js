// In-process scanner for agent sessions the Gateway never sees.
//
// Replaces the standalone Python watcher: the monitor owns this directly, so
// there is no second process, no python3 dependency, and no JSON file handed
// between them. Gateway sessions are deliberately absent — the monitor already
// holds those live over socket RPC, and the old watcher only produced them for
// `mergeMonitorSessions` to throw away again.

import { watch } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { detectClaudeSessions } from "./claude.js";
import { discover, poll, prune } from "./codex.js";
import { detectCliProcesses, recordGrokAcpLinks } from "./grok.js";
import { detectOrcaSessions } from "./orca.js";
import { externalParent, pruneExternalParents } from "./parent-links.js";
import { snapshotSessions } from "./snapshot.js";

const DISCOVERY_INTERVAL_SECONDS = 2;
// ps costs ~25ms CPU per pass; grok is its only consumer and a new grok
// session appearing a few seconds late is fine, so the process scan runs on
// its own slower cadence than file-based discovery.
const PROCESS_SCAN_INTERVAL_SECONDS = 5;
const DEFAULT_READY_AFTER = 3;
const DEFAULT_STALE_AFTER = 600;

function defaultPaths() {
  const home = homedir();
  return {
    sessionsRoot: join(home, ".codex", "sessions"),
    database: join(home, ".codex", "state_5.sqlite"),
    claudeRoot: join(home, ".claude", "projects"),
    grokRoot: join(home, ".grok", "sessions"),
    orcaAccounts: join(home, "Library", "Application Support", "Orca", "codex-accounts"),
    orcaStatus: join(home, "Library", "Application Support", "Orca", "agent-hooks", "last-status.json")
  };
}

export class LocalAgentScanner {
  constructor(options = {}) {
    const paths = { ...defaultPaths(), ...options };
    this.sessionsRoot = paths.sessionsRoot;
    this.database = paths.database;
    this.claudeRoot = paths.claudeRoot;
    this.grokRoot = paths.grokRoot;
    this.orcaAccounts = paths.orcaAccounts;
    this.orcaStatus = paths.orcaStatus;
    this.readyAfter = paths.readyAfter ?? DEFAULT_READY_AFTER;
    this.staleAfter = paths.staleAfter ?? DEFAULT_STALE_AFTER;
    this.discoveryIntervalSeconds = paths.discoveryIntervalSeconds ?? DISCOVERY_INTERVAL_SECONDS;

    this.cursors = new Map();
    this.retired = new Map();
    this.codexStates = {};
    this.detectedStates = {};
    this.claudeCache = new Map();
    // Grok process facts, refreshed on their own slower cadence.
    this.processStates = {};
    this.grokEventPathCache = new Map();
    this.lastProcessScan = 0;
    // FSEvents watcher over the Claude projects tree. While healthy, each
    // discovery only touches transcripts the watcher marked dirty; a periodic
    // full walk self-heals anything the watcher missed (directory renames,
    // dropped events), and any watcher failure falls back to walking.
    this.claudeWatcher = null;
    this.claudeDirty = new Set();
    this.claudeWatchBroken = false;
    this.lastClaudeFullWalk = 0;
    this.claudeFullWalkIntervalSeconds = paths.claudeFullWalkIntervalSeconds ?? 60;
    // Parent links are in-memory now. The old watcher reloaded them from its
    // snapshot file; here a monitor restart simply rediscovers them from the
    // transcripts on the next scan.
    this.parents = new Map();
    this.lastDiscovery = 0;
  }

  /**
   * Conversation records the codex tailer retained for one session — the
   * event projection's input, served from the same single read that produced
   * the session's state.
   */
  conversationRecords(sessionId) {
    for (const cursor of this.cursors.values()) {
      if (cursor.session === sessionId) return cursor.conversation;
    }
    return [];
  }

  /** Every known local session, shaped like the old watcher's snapshot entries. */
  async scan(now = Date.now() / 1000) {
    if (now - this.lastDiscovery >= this.discoveryIntervalSeconds) {
      await this.#discover(now);
      this.lastDiscovery = now;
    }
    await poll({ cursors: this.cursors, states: this.codexStates, parents: this.parents, now });
    prune({
      cursors: this.cursors,
      states: this.codexStates,
      retired: this.retired,
      readyAfter: this.readyAfter,
      staleAfter: this.staleAfter,
      now
    });
    pruneExternalParents(this.parents, this.detectedStates, this.staleAfter, now);
    return snapshotSessions({ ...this.codexStates, ...this.detectedStates }, this.database);
  }

  async #discover(now) {
    await discover({
      root: this.sessionsRoot,
      cursors: this.cursors,
      retired: this.retired,
      staleAfter: this.staleAfter,
      now,
      database: this.database
    });

    // Each Orca account keeps its own Codex home, transcripts and database.
    for (const home of await this.#orcaHomes()) {
      await discover({
        root: join(home, "sessions"),
        cursors: this.cursors,
        retired: this.retired,
        staleAfter: this.staleAfter,
        now,
        database: join(home, "state_5.sqlite")
      });
    }

    if (now - this.lastProcessScan >= (this.processScanIntervalSeconds ?? PROCESS_SCAN_INTERVAL_SECONDS)) {
      this.processStates = await detectCliProcesses(now, this.processStates, this.parents, this.grokEventPathCache);
      this.lastProcessScan = now;
    }
    // Copy each carried-over entry: later stages mutate item.parent in place,
    // and the retained processStates must stay what the scan itself reported.
    let detected = Object.fromEntries(
      Object.entries(this.processStates).map(([key, item]) => [key, { ...item }])
    );
    Object.assign(detected, await detectClaudeSessions(
      this.claudeRoot, now, this.readyAfter, this.staleAfter, this.parents, this.claudeCache,
      this.#claudeDirtySnapshot(now)
    ));

    // Orca drives the same underlying CLI sessions, so its richer status wins
    // over whatever the process scan inferred for the same session.
    const orcaStates = await detectOrcaSessions(this.orcaStatus, now, this.readyAfter, this.staleAfter);
    const orcaSessions = new Set(Object.keys(orcaStates));
    detected = Object.fromEntries(
      Object.entries(detected).filter(([, item]) => !orcaSessions.has(item.link_session ?? item.session))
    );
    Object.assign(detected, orcaStates);

    if (await recordGrokAcpLinks(detected, this.parents, now, this.grokRoot)) {
      for (const item of Object.values(detected)) {
        if (["claude", "grok", "codex"].includes(item.provider) && !item.parent) {
          item.parent = externalParent(this.parents, item.provider, item.link_session ?? item.session);
        }
      }
    }
    this.detectedStates = detected;
  }

  /**
   * The dirty set for this discovery pass, or null to force a full walk.
   * Null when: the watcher cannot run (fallback), an event arrived that the
   * incremental path cannot attribute (broken/renamed), or the periodic
   * self-heal walk is due.
   */
  #claudeDirtySnapshot(now) {
    this.#ensureClaudeWatcher();
    const healDue = now - this.lastClaudeFullWalk >= this.claudeFullWalkIntervalSeconds;
    if (!this.claudeWatcher || this.claudeWatchBroken || healDue) {
      this.claudeWatchBroken = false;
      this.claudeDirty.clear();
      this.lastClaudeFullWalk = now;
      return null;
    }
    const dirty = this.claudeDirty;
    this.claudeDirty = new Set();
    return dirty;
  }

  #ensureClaudeWatcher() {
    if (this.claudeWatcher) return;
    try {
      this.claudeWatcher = watch(this.claudeRoot, { recursive: true }, (_eventType, filename) => {
        if (typeof filename !== "string" || !filename) {
          // An event we cannot attribute to a path: the next pass walks.
          this.claudeWatchBroken = true;
          return;
        }
        if (filename.endsWith(".jsonl")) this.claudeDirty.add(join(this.claudeRoot, filename));
      });
      this.claudeWatcher.unref();
      this.claudeWatcher.on("error", () => {
        // Missing root, exhausted watch descriptors, ... — fall back to
        // walking; the next #ensureClaudeWatcher call retries.
        this.claudeWatcher?.close();
        this.claudeWatcher = null;
        this.claudeWatchBroken = true;
      });
      // Everything before the watcher existed is unknown: walk once.
      this.claudeWatchBroken = true;
    } catch {
      this.claudeWatcher = null;
    }
  }

  async #orcaHomes() {
    if (!this.orcaAccounts) return [];
    const { readdir } = await import("node:fs/promises");
    try {
      const entries = await readdir(this.orcaAccounts, { withFileTypes: true });
      return entries.filter((entry) => entry.isDirectory()).map((entry) => join(this.orcaAccounts, entry.name, "home"));
    } catch {
      return [];
    }
  }
}
