import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { MonitorState } from "../src/projection/monitor-state.js";
import { annotateRuntimeSplit, annotateSupersededDaemon, compareReleases, restartBlockedError } from "../src/server/monitor.js";

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
  const error = restartBlockedError(["진행 중 세션 1개", "미응답 요청 1개"]);
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
  const unverified = annotateRuntimeSplit({ gatewayVersion: "1.4.0" }, monitorRoot, "new");
  assert.deepEqual(unverified.runtimeIdentity, {
    status: "unverified",
    monitorBuildId: "new",
    reason: "Gateway setup does not expose gatewayBuildId"
  });
});

// Regression: a 1.4.0 daemon kept serving for days after runtime/current moved
// to 1.6.0, because nothing restarted it once the update was activated.
test("a daemon older than the runtime is restarted when idle, or left to the user", () => {
  const split = (gatewayVersion) => ({ gatewayVersion, runtimeSplit: { daemonBuildId: "old", monitorBuildId: "new" } });
  assert.equal(annotateSupersededDaemon(split("1.6.0"), "1.7.2").supersededDaemon.plan, "restart");
  assert.deepEqual(annotateSupersededDaemon(split("1.6.0"), "1.7.2", ["진행 중 세션 1개"]).supersededDaemon,
    { daemonVersion: "1.6.0", runtimeVersion: "1.7.2", plan: "blocked", blockers: ["진행 중 세션 1개"] });
  assert.equal(annotateSupersededDaemon(split("1.4.0"), "1.6.0").supersededDaemon.plan, "manual",
    "a daemon without shutdown_if_idle is never stopped unasked");
  assert.equal(annotateSupersededDaemon(split("1.8.0"), "1.7.2").supersededDaemon, undefined, "a newer daemon is a dev checkout");
  assert.equal(annotateSupersededDaemon({ gatewayVersion: "1.4.0" }, "1.7.2").supersededDaemon, undefined, "no split, nothing to do");
  assert.equal(annotateSupersededDaemon(split("1.4.0"), null).supersededDaemon, undefined);
  assert.equal(compareReleases("1.10.0", "1.9.9"), 1);
  assert.equal(compareReleases("1.7.2-beta", "1.7.2"), 0);
  assert.equal(compareReleases("dev", "1.7.2"), null);
});
