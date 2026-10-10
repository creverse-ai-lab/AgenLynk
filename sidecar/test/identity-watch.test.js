import assert from "node:assert/strict";
import { mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { identityChanged, identityFrom, watchIdentity } from "../src/app/identity-watch.js";

const installState = (token, extra = {}) => JSON.stringify({ identity: { token, rootId: "main" }, ...extra });

test("only another token or root id counts as a changed identity", async () => {
  const dir = await mkdtemp(join(tmpdir(), "identity-"));
  try {
    const path = join(dir, "install.json");
    await writeFile(path, installState("old"));
    const current = identityFrom(path);
    assert.deepEqual(current, { token: "old", rootId: "main" });
    // The installer rewrites install.json for its own records too.
    await writeFile(path, installState("old", { managedMcp: { "codex:agent-acp": {} } }));
    assert.equal(identityChanged(current, path), false);
    await writeFile(path, "{ torn");
    assert.equal(identityChanged(current, path), false, "an unreadable file is no change");
    await writeFile(path, installState("new"));
    assert.equal(identityChanged(current, path), true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// Gateway 1.8 recommends --rotate-token after an update; the monitor read the
// identity once and was refused on every call until the app restarted. File
// events are not awaited here: on a busy machine they come late, which is
// why the monitor also checks when the Gateway refuses its token.
test("a rotated token is acted on once, however often it is checked", async () => {
  const dir = await mkdtemp(join(tmpdir(), "identity-"));
  try {
    const path = join(dir, "install.json");
    await writeFile(path, installState("old"));
    let calls = 0;
    const watch = watchIdentity(path, identityFrom(path), () => { calls += 1; }, { delayMs: 10_000 });
    try {
      watch.check();
      assert.equal(calls, 0, "the same identity is no change");
      await writeFile(join(dir, "install.json.tmp"), installState("rotated"));
      await rename(join(dir, "install.json.tmp"), path);
      watch.check();
      watch.check();
      assert.equal(calls, 1);
    } finally {
      watch.stop();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("Gateway 1.8's new errors read in Korean with their code; others keep their message", async () => {
  const { describeGatewayError } = await import("../src/app/gateway-errors.js");
  const socket = Object.assign(new Error("socket directory is writable by others"), { code: "SOCKET_UNTRUSTED" });
  assert.match(describeGatewayError(socket), /ACP_GATEWAY_SOCKET.*\(SOCKET_UNTRUSTED\)$/);
  assert.equal(describeGatewayError(Object.assign(new Error("boom"), { code: "SOMETHING_ELSE" })), "boom");
  assert.equal(describeGatewayError(new Error("plain")), "plain");
});

// After a rotation the daemon keeps the old token and refuses daemon_shutdown
// from the monitor; Gateway 1.8 says to SIGTERM the pid in <socket>.lock.
test("only a lock pid that runs the Gateway daemon is sent SIGTERM", async () => {
  const { runsGatewayDaemon, terminateLockedDaemon } = await import("../src/app/daemon-lock.js");
  assert.equal(runsGatewayDaemon("/rt/node/bin/node /rt/node_modules/acp-gateway-daemon/src/gateway-daemon.js"), true);
  assert.equal(runsGatewayDaemon("/usr/bin/vim notes-about-gateway-daemon.js.txt"), false);
  const killed = [];
  const run = (lock, command) => terminateLockedDaemon("/tmp/gw.sock", {
    readLock: async () => lock,
    commandOf: async () => command,
    kill: (pid, signal) => killed.push([pid, signal])
  });
  assert.equal(await run("4242\n", "node /x/src/gateway-daemon.js"), true);
  assert.deepEqual(killed, [[4242, "SIGTERM"]]);
  assert.equal(await run("4243", "/Applications/Other.app/Contents/MacOS/Other"), false, "a reused pid");
  assert.equal(await run("", "node /x/src/gateway-daemon.js"), false, "no lock");
  assert.equal(await run("1", "node /x/src/gateway-daemon.js"), false);
  assert.equal(killed.length, 1);
});
