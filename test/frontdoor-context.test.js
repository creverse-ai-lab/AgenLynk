import assert from "node:assert/strict";
import test from "node:test";
import {
  detectFrontdoorContext,
  frontdoorContextForRequest,
  sessionIdFromCommand
} from "../src/frontdoor-context.js";
import {
  ACP_PROCESS_ROLE,
  delegatedWorkerEnvironment,
  gatewayDaemonEnvironment,
  isDelegatedWorkerEnvironment
} from "../src/process-environment.js";

test("Frontdoor context prefers the real Codex thread id", () => {
  const context = detectFrontdoorContext({
    env: { CODEX_THREAD_ID: "019f-main-thread" },
    parentPid: 42,
    processInfo: { comm: "/Applications/Codex.app/Codex", command: "codex", startedAt: "now" }
  });
  assert.equal(context.agent, "codex");
  assert.equal(context.sessionId, "019f-main-thread");
  assert.equal(context.instanceId, "019f-main-thread");
});

test("Frontdoor context extracts Claude resume ids and has a stable process fallback", () => {
  assert.equal(
    sessionIdFromCommand("claude --model opus --resume=faf91dcb-28e0-4797-a0d3-30059adf784b"),
    "faf91dcb-28e0-4797-a0d3-30059adf784b"
  );
  const fromCommand = detectFrontdoorContext({
    env: {},
    parentPid: 7,
    processInfo: {
      comm: "claude",
      command: "claude --resume faf91dcb-28e0-4797-a0d3-30059adf784b",
      startedAt: "Fri Aug 7"
    }
  });
  assert.equal(fromCommand.agent, "claude");
  assert.equal(fromCommand.instanceId, "faf91dcb-28e0-4797-a0d3-30059adf784b");

  const fallback = detectFrontdoorContext({
    env: {},
    parentPid: 7,
    processInfo: { comm: "codex", command: "codex", startedAt: "Fri Aug 7" }
  });
  assert.match(fallback.instanceId, /^process:[A-Za-z0-9_-]{24}$/);
  assert.equal(fallback.sessionId, null);
});

test("MCP request metadata overrides the process fallback with the active Codex thread", () => {
  const base = detectFrontdoorContext({
    env: {},
    parentPid: 7,
    processInfo: { comm: "node", command: "node smoke-test-for-grok", startedAt: "Fri Aug 7" }
  });
  assert.equal(base.agent, "grok");
  const context = frontdoorContextForRequest(base, {
    progressToken: 12,
    threadId: "019fdac3-9cf1-7fc2-8d84-ceebe6fe997e",
    "x-codex-turn-metadata": {
      session_id: "019fdac3-9cf1-7fc2-8d84-ceebe6fe997e",
      thread_id: "019fdac3-9cf1-7fc2-8d84-ceebe6fe997e",
      turn_id: "019fdae0-79f9-7c63-9ae4-e39fffdcc66a"
    }
  });
  assert.equal(context.agent, "codex");
  assert.equal(context.sessionId, "019fdac3-9cf1-7fc2-8d84-ceebe6fe997e");
  assert.equal(context.instanceId, "019fdac3-9cf1-7fc2-8d84-ceebe6fe997e");
});

test("MCP request metadata supports nested session ids from other Frontdoors", () => {
  const base = { agent: "claude", sessionId: null, instanceId: "process:fallback" };
  const context = frontdoorContextForRequest(base, {
    "x-claude-code": { session_id: "claude-main-session-1234" }
  });
  assert.equal(context.agent, "claude");
  assert.equal(context.instanceId, "claude-main-session-1234");
});

test("Worker and daemon environments strip Frontdoor identity", () => {
  const source = {
    PATH: "/bin",
    CODEX_THREAD_ID: "main-thread",
    CLAUDE_SESSION_ID: "main-claude",
    ACP_FRONTDOOR_SESSION_ID: "override",
    ACP_GATEWAY_CONTROL_TOKEN: "secret",
    ACP_GATEWAY_ROOT_ID: "main-root",
    ACP_GATEWAY_SOCKET: "/tmp/socket"
  };
  const worker = delegatedWorkerEnvironment(source, { WORKER_VALUE: "kept" });
  assert.deepEqual(worker, {
    PATH: "/bin",
    WORKER_VALUE: "kept",
    [ACP_PROCESS_ROLE]: "worker"
  });
  assert.equal(isDelegatedWorkerEnvironment(worker), true);

  const daemon = gatewayDaemonEnvironment(source, {
    ACP_GATEWAY_CONTROL_TOKEN: "new-secret",
    ACP_GATEWAY_ROOT_ID: "new-root"
  });
  assert.equal(daemon.CODEX_THREAD_ID, undefined);
  assert.equal(daemon.CLAUDE_SESSION_ID, undefined);
  assert.equal(daemon[ACP_PROCESS_ROLE], undefined);
  assert.equal(daemon.ACP_GATEWAY_CONTROL_TOKEN, "new-secret");
  assert.equal(daemon.ACP_GATEWAY_ROOT_ID, "new-root");
});
