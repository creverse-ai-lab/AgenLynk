import assert from "node:assert/strict";
import test from "node:test";
import { MainStatusBook, withMainStatus } from "../src/gateway/main-status.js";

const claude = { provider: "claude", sessionId: "c-1", instanceId: "mcp-a" };
const waiting = (revision, extra = {}) => ({
  type: "main_status", caller: claude, status: "waiting_tasks", since: "2026-10-11T00:00:00.000Z",
  taskIds: ["t1"], count: 1, revision, ...extra
});

// Gateway 1.9: an event and a main_list reply can overtake each other, so
// per Main the higher revision wins.
test("per Main the higher revision wins, whichever arrives first", () => {
  const book = new MainStatusBook();
  assert.equal(book.apply(waiting(5)), true, "a Main starts waiting");
  assert.equal(book.apply({ caller: claude, status: "active", since: "x", revision: 4 }), false, "an older reply changes nothing");
  assert.equal(book.waiting().length, 1);
  assert.equal(book.apply(waiting(6)), false, "the same wait again is no change");
  assert.equal(book.apply(waiting(7, { taskIds: ["t1", "t2"], count: 2 })), true, "what it waits on is");
  assert.equal(book.apply({ caller: claude, status: "active", since: "y", revision: 8 }), true, "awake again");
  assert.equal(book.waiting().length, 0);
});

test("a gone Main does not come back with an older list entry", () => {
  const book = new MainStatusBook();
  book.apply(waiting(3));
  assert.equal(book.apply({ caller: claude, status: "gone", since: "z", revision: 9 }), true);
  assert.equal(book.replace([waiting(4)]), false, "the list read before it left");
  assert.equal(book.waiting().length, 0);
  book.reset();
  assert.equal(book.replace([waiting(1)]), true, "a restarted daemon numbers from the start again");
});

test("an entry without a caller instance is ignored", () => {
  const book = new MainStatusBook();
  assert.equal(book.apply({ status: "waiting_tasks", revision: 1 }), false);
  assert.equal(book.apply({ caller: { sessionId: "x" }, status: "waiting_tasks", revision: 1 }), false);
  assert.equal(book.size, 0);
});

const sessions = () => [
  { sessionId: "local:claude:c-1", role: "frontdoor", source: "local", status: "running" },
  { sessionId: "local:codex:t-9", role: "frontdoor", source: "local", status: "running" },
  { sessionId: "acp-w", role: "worker", source: "gateway", status: "running" }
];

test("a waiting Main's Frontdoor reads waiting_tasks; its Workers keep their own status", () => {
  const book = new MainStatusBook();
  book.apply(waiting(1));
  const shown = withMainStatus(sessions(), book.waiting());
  assert.equal(shown[0].status, "waiting_tasks");
  assert.deepEqual(shown[0].mainStatus, { status: "waiting_tasks", since: "2026-10-11T00:00:00.000Z", taskIds: ["t1"], count: 1 });
  assert.equal(shown[1].status, "running");
  assert.equal(shown[2].status, "running");
});

test("only a Frontdoor in a turn is changed: a heartbeat's grace outlives a finished turn", () => {
  const book = new MainStatusBook();
  book.apply(waiting(1));
  const idle = sessions().map((session) => (session.sessionId === "local:claude:c-1" ? { ...session, status: "idle" } : session));
  assert.equal(withMainStatus(idle, book.waiting())[0].status, "idle");
  const asking = sessions().map((session) => (session.sessionId === "local:claude:c-1" ? { ...session, status: "waiting_permission" } : session));
  assert.equal(withMainStatus(asking, book.waiting())[0].status, "waiting_permission");
});

test("a Main is found by the session its process holds now, or by its Workers' topology", () => {
  const book = new MainStatusBook();
  // A Claude Main that moved to another session (the pid file says which).
  book.apply({ caller: { provider: "claude", sessionId: "old", instanceId: "mcp-b", pid: 42 }, status: "waiting_tasks", revision: 1 });
  // An older Codex front door names no thread, only its instance.
  book.apply({ caller: { provider: "codex", instanceId: "codex-inst" }, status: "waiting_tasks", revision: 2 });
  const topology = new Map([["caller:codex-inst", { parentSessionId: "local:codex:t-9" }]]);
  const shown = withMainStatus(sessions(), book.waiting(), {
    workerTopology: topology,
    currentCallerSession: (caller) => (caller.pid === 42 ? "c-1" : null)
  });
  assert.deepEqual(shown.map((session) => session.status), ["waiting_tasks", "waiting_tasks", "running"]);
});

test("no waiting Main leaves the list as it was", () => {
  const list = sessions();
  assert.equal(withMainStatus(list, []), list);
});

// A Main's going is an event that is never replayed: lost with a connection,
// the next main_list must still end the wait, or the Pet stays awaiting.
test("a Main missing from main_list is gone, unless an event touched it after the list was asked for", () => {
  const book = new MainStatusBook();
  book.apply(waiting(3));
  const other = { provider: "codex", sessionId: "t-9", instanceId: "codex-inst" };
  const epoch = book.beginList();
  // Arrives while the list is in flight, newer than what the list says.
  book.apply({ caller: other, status: "waiting_tasks", taskIds: ["t2"], count: 1, revision: 12 });
  assert.equal(book.replace([], epoch), true, "the lost going of claude is made up for");
  assert.deepEqual(book.waiting().map((main) => main.caller.instanceId), ["codex-inst"]);
  assert.equal(book.replace([], book.beginList()), true, "and codex goes once a later list leaves it out");
  assert.equal(book.waiting().length, 0);
});

test("a Frontdoor two Mains map to waits only while neither is awake", () => {
  const book = new MainStatusBook();
  book.apply(waiting(1));
  book.apply({ caller: { provider: "claude", sessionId: "c-1", instanceId: "mcp-other" }, status: "active", since: "x", revision: 2 });
  assert.equal(withMainStatus(sessions(), book.present())[0].status, "running");
});

test("a Main whose session is not a listed Frontdoor falls back to its Workers' topology; Workers never change", () => {
  const book = new MainStatusBook();
  book.apply({ caller: { provider: "codex", sessionId: "unscanned-thread", instanceId: "codex-inst" }, status: "waiting_tasks", revision: 1 });
  book.apply({ caller: { provider: "claude", sessionId: "acp-w", instanceId: "mcp-w" }, status: "waiting_tasks", revision: 2 });
  const topology = new Map([["caller:codex-inst", { parentSessionId: "local:codex:t-9" }]]);
  const shown = withMainStatus(sessions(), book.present(), { workerTopology: topology });
  assert.deepEqual(shown.map((session) => session.status), ["running", "waiting_tasks", "running"]);
});
