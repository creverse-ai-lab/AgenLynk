import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { fileURLToPath } from "node:url";

const monitorPath = fileURLToPath(new URL("../src/server/monitor.js", import.meta.url));
const publicClient = fileURLToPath(new URL("./fixtures/monitor-orchestration/gateway-client/index.js", import.meta.url));

test("live sidecar make-before-break rewind keeps old events and promotes one subscription", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "agenlynk-monitor-orch-"));
  const controlFile = join(temporary, "control.json");
  const child = spawn(process.execPath, ["--disable-warning=ExperimentalWarning", monitorPath], {
    env: {
      ...process.env,
      ACP_GATEWAY_CLIENT_ENTRYPOINT: publicClient,
      ACP_GATEWAY_TEST_CONTROL_FILE: controlFile,
      ACP_GATEWAY_CONTROL_TOKEN: "orchestration-control-token-123456",
      ACP_GATEWAY_ROOT_ID: "orchestration-root",
      ACP_GATEWAY_INSTALL_STATE: join(temporary, "install.json"),
      ACP_GATEWAY_MONITOR_PORT: "0",
      ACP_GATEWAY_MONITOR_AUTOSTART: "0",
      ACP_MONITOR_LOCAL_SCANNER: "0",
      ACP_GATEWAY_ACTIVE_ROOT: temporary
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  try {
    const ready = await waitForReady(child, () => stderr);
    const headers = { authorization: `Bearer ${ready.apiToken}` };
    const control = await waitFor(async () => {
      try { return JSON.parse(await readFile(controlFile, "utf8")); }
      catch { return false; }
    }, "orchestration control file did not appear");

    await waitFor(async () => {
      const snapshot = await fetchJson(`${ready.url}/api/snapshot`, { headers });
      const sequences = snapshot.events?.["s-live"]?.map((event) => event.sequence) ?? [];
      return snapshot.streaming && sequences[0] === 0 && sequences.includes(3) ? snapshot : false;
    }, "initial rewind snapshot did not land");

    await waitFor(async () => {
      const status = await fetchJson(`${control.url}/status`);
      return status.subscribeCalls.length >= 1 ? status : false;
    }, "initial subscribe was not recorded");

    await fetchJson(`${control.url}/emit`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        event: {
          type: "subscription_gap",
          sessionId: "s-live",
          fromSequence: 1,
          toSequence: 2,
          droppedCount: 2,
          reason: "slow_subscriber"
        }
      })
    });

    await waitFor(async () => {
      const status = await fetchJson(`${control.url}/status`);
      return status.candidateHeld && status.subscribeCalls.length === 2 ? status : false;
    }, "candidate rewind subscribe was not held");

    await fetchJson(`${control.url}/emit`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        subscriptionId: "sub-1",
        event: {
          sessionId: "s-live",
          sequence: 4,
          type: "agent_message_chunk",
          ts: "2026-08-13T00:00:04.000Z",
          text: "old-live"
        }
      })
    });

    await fetchJson(`${control.url}/release-candidate`, { method: "POST" });

    const snapshot = await waitFor(async () => {
      const value = await fetchJson(`${ready.url}/api/snapshot`, { headers });
      const sequences = value.events?.["s-live"]?.map((event) => event.sequence) ?? [];
      return sequences.join(",") === "0,1,2,3,4" && value.streamHealth === "healthy" ? value : false;
    }, "promoted snapshot did not reach canonical sequences");
    const status = await fetchJson(`${control.url}/status`);

    assert.equal(snapshot.events["s-live"].some((event) => event.type === "subscription_gap"), false);
    assert.deepEqual(status.subscribeCalls.map((item) => item.subscriptionId), ["sub-1", "sub-2"]);
    assert.deepEqual(status.subscribeCalls[1].cursors, { "s-live": 1 });
    assert.equal(status.subscribeCalls[1].includeThoughts, true);
    assert.equal(status.subscribeCalls[1].includeToolEvents, true);
    assert.equal(status.subscribeCalls[1].acceptsGaps, true);
    assert.deepEqual(status.active, ["sub-2"]);
    assert.deepEqual(status.unsubscribed, ["sub-1"]);
    assert.equal(snapshot.diagnostics.subscriptionGaps, 1);
    assert.equal(snapshot.diagnostics.replayedEvents, 4);
    assert.equal(snapshot.diagnostics.reconciliationRuns, 1);
    assert.equal(snapshot.diagnostics.replayTruncations, 0);
    assert.equal(snapshot.streaming, true);
    assert.equal(snapshot.error, null);
    assert.equal(stderr.includes("Gateway connection failed"), false);
  } finally {
    if (child.exitCode == null) {
      child.kill("SIGTERM");
      await new Promise((resolve) => child.once("exit", resolve));
    }
    await rm(temporary, { recursive: true, force: true });
  }
});

async function fetchJson(url, init) {
  const response = await fetch(url, init);
  const text = await response.text();
  assert.ok(response.ok, `${url} -> ${response.status} ${text}`);
  return text ? JSON.parse(text) : {};
}

async function waitFor(predicate, message) {
  let last = null;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    last = await predicate();
    if (last) return last;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(message);
}

async function waitForReady(child, readStderr = () => "") {
  const lines = createInterface({ input: child.stdout });
  const timeout = setTimeout(() => {
    child.kill("SIGTERM");
  }, 8_000);
  try {
    for await (const line of lines) {
      if (!line.includes("monitor_ready")) continue;
      return JSON.parse(line);
    }
  } finally {
    clearTimeout(timeout);
    lines.close();
  }
  if (child.exitCode == null) {
    await new Promise((resolve) => child.once("exit", resolve));
  }
  throw new Error(`sidecar exited before monitor_ready (${child.exitCode}): ${readStderr()}`);
}
