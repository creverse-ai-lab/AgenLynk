import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { MonitorState } from "../src/projection/monitor-state.js";
import { annotateRuntimeSplit, restartBlockedError } from "../src/server/monitor.js";

test("restartBlockers matches the shared blocker contract the Settings UI also implements", async () => {
  const { cases } = JSON.parse(await readFile(new URL("./fixtures/restart-blockers.json", import.meta.url), "utf8"));
  for (const { name, sessions, tasks, inbox, expected } of cases) {
    const state = new MonitorState();
    state.setSessions(sessions.map((session) => ({ provider: "codex", cwd: "/tmp/project", ...session })));
    state.setRecords({ tasks, inbox });
    assert.deepEqual(state.restartBlockers(), expected, name);
  }
});

test("restartBlockedError reports the stable monitor_restart_blocked code and blocker detail", () => {
  const error = restartBlockedError(["진행 중 세션 1개", "미응답 Inbox 1개"]);
  assert.equal(error.statusCode, 409);
  assert.equal(error.code, "monitor_restart_blocked");
  assert.match(error.message, /진행 중 세션 1개/);
});

test("runtime-root and build mismatches are flagged as split brain", () => {
  const monitorRoot = "/Users/x/.acp-gateway/runtime/versions/1.4.0-new/gateway";
  const foreign = annotateRuntimeSplit({ runtimeRoot: "/Users/x/dev/checkout" }, monitorRoot);
  assert.deepEqual(foreign.runtimeSplit, { daemonRuntimeRoot: "/Users/x/dev/checkout", monitorRuntimeRoot: monitorRoot });
  assert.equal(annotateRuntimeSplit({ runtimeRoot: monitorRoot }, monitorRoot).runtimeSplit, undefined);
  const stale = annotateRuntimeSplit({ runtimeRoot: monitorRoot, gatewayBuildId: "old" }, monitorRoot, "new");
  assert.deepEqual(stale.runtimeSplit, { daemonBuildId: "old", monitorBuildId: "new" });
});
