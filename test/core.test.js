import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { AcpClient, requirePermissionPolicy } from "../src/acp-client.js";
import { providerConfig } from "../src/providers.js";
import { SessionStore } from "../src/sessions.js";

const capabilityAgent = fileURLToPath(new URL("./mock-capability-agent.js", import.meta.url));

test("provider policies are explicit", () => {
  const grok = providerConfig("grok");
  assert.equal(grok.permissionPolicy, "ask");
  assert.deepEqual(grok.args.slice(0, 4), ["--sandbox", "off", "--permission-mode", "default"]);
  assert.equal(grok.args.includes("--no-subagents"), false);
  const otherGrok = providerConfig("grok", { model: "grok-test" });
  assert.equal(otherGrok.args[otherGrok.args.indexOf("--model") + 1], "grok-test");
  assert.equal(otherGrok.expectedModel, "grok-test");
  assert.equal(providerConfig("claude").permissionPolicy, "ask");
  assert.equal(requirePermissionPolicy("auto_approve"), "auto_approve");
  assert.throws(() => requirePermissionPolicy("bypass"), /permissionPolicy must be one of/);
  assert.throws(() => providerConfig("other"), /provider must be one of/);
});

test("ACP auto approval accepts an agent that only offers allow_always", async () => {
  const client = new AcpClient({
    provider: "mock",
    command: process.execPath,
    args: [fileURLToPath(new URL("./mock-agent.js", import.meta.url))],
    permissionPolicy: "auto_approve"
  });
  let text = "";
  try {
    await client.start();
    const session = await client.sessionNew({ cwd: process.cwd(), permissionPolicy: "auto_approve" });
    client.onSessionUpdate(session.sessionId, (update) => {
      if (update.sessionUpdate === "agent_message_chunk") text += update.content.text;
      assert.notEqual(update.sessionUpdate, "permission_request");
    });
    await client.sessionPrompt({ sessionId: session.sessionId, prompt: "allow-always-only" });
    assert.equal(text, "READY DONE");
  } finally {
    await client.stop();
  }
});

test("Session text limits are UTF-8 byte based and never split Unicode", () => {
  const store = new SessionStore({ maxTextBytes: 9 });
  const trimmed = store.trimText(`prefix-${"😀".repeat(4)}`);
  assert.ok(Buffer.byteLength(trimmed) <= 9);
  assert.doesNotMatch(trimmed, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/);
  assert.doesNotMatch(trimmed, /�/);
  assert.ok(trimmed.endsWith("😀"));
});

test("SessionStore bounded text accumulator matches full trim semantics across many small appends", () => {
  const store = new SessionStore({ maxTextBytes: 32 });
  const session = store.create({ id: "bounded-text-test", ownerRootId: "main-a" });
  let expected = "";
  for (let i = 0; i < 500; i += 1) {
    const part = i % 7 === 0 ? "😀" : `x${i}`;
    expected = store.trimText(expected + part);
    store.appendResultText(session, part);
  }
  assert.equal(session.resultText, expected);
  assert.ok(Buffer.byteLength(session.resultText) <= 32);
  assert.doesNotMatch(session.resultText, /�/);
});

test("SessionStore preserves a Unicode surrogate pair split across message chunks", () => {
  const store = new SessionStore({ maxTextBytes: 32 });
  const session = store.create({ id: "split-surrogate-test", ownerRootId: "main-a" });
  store.appendResultText(session, "\uD83D");
  store.appendResultText(session, "\uDE00");
  assert.equal(session.resultText, "😀");
  assert.doesNotMatch(session.resultText, /�/);
});

test("SessionStore withholds an incomplete surrogate without exceeding its byte limit", () => {
  const store = new SessionStore({ maxTextBytes: 3 });
  const session = store.create({ id: "incomplete-surrogate-test", ownerRootId: "main-a" });
  store.appendResultText(session, "\uD83D");
  assert.equal(session.resultText, "");
  assert.ok(Buffer.byteLength(session.resultText) <= 3);
  store.appendResultText(session, "\uDE00");
  assert.equal(session.resultText, "");
  assert.ok(Buffer.byteLength(session.resultText) <= 3);
});

test("ACP prompt waits for an explicit permission response", async () => {
  const client = new AcpClient(
    {
      provider: "mock",
      command: process.execPath,
      args: [fileURLToPath(new URL("./mock-agent.js", import.meta.url))],
      permissionPolicy: "ask"
    },
    { permissionPolicy: "ask" }
  );
  let text = "";
  let requestId;
  try {
    await client.start();
    const created = await client.sessionNew({ cwd: process.cwd() });
    client.onSessionUpdate(created.sessionId, (update) => {
      if (update.sessionUpdate === "agent_message_chunk") text += update.content.text;
      if (update.sessionUpdate === "permission_request") requestId = update.requestId;
    });
    const turn = client.sessionPrompt({ sessionId: created.sessionId, prompt: "go" });
    while (requestId == null) await new Promise((done) => setImmediate(done));
    assert.throws(
      () => client.respondPermission(requestId, "allow-once", "another-session"),
      /belongs to another session/
    );
    client.respondPermission(requestId, "allow-once", created.sessionId);
    assert.deepEqual(await turn, { stopReason: "end_turn" });
    assert.equal(text, "READY DONE");
  } finally {
    await client.stop();
  }
});

test("ACP session policy automatically allows or rejects edits", async () => {
  for (const [permissionPolicy, expected] of [
    ["auto_approve", "READY DONE"],
    ["read_only", "READY DENIED"]
  ]) {
    const client = new AcpClient({
      provider: "mock",
      command: process.execPath,
      args: [fileURLToPath(new URL("./mock-agent.js", import.meta.url))],
      permissionPolicy: "ask"
    });
    let text = "";
    try {
      await client.start();
      const created = await client.sessionNew({ cwd: process.cwd(), permissionPolicy });
      client.onSessionUpdate(created.sessionId, (update) => {
        if (update.sessionUpdate === "agent_message_chunk") text += update.content.text;
        assert.notEqual(update.sessionUpdate, "permission_request");
      });
      assert.deepEqual(
        await client.sessionPrompt({ sessionId: created.sessionId, prompt: "go" }),
        { stopReason: "end_turn" }
      );
      assert.equal(text, expected);
    } finally {
      await client.stop();
    }
  }
});

test("ACP full access writes files and completes terminal lifecycle", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-capability-"));
  const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "ask" });
  try {
    await client.start();
    const session = await client.sessionNew({ cwd: directory, permissionPolicy: "auto_approve" });
    assert.equal((await client.sessionPrompt({ sessionId: session.sessionId, prompt: "write" })).stopReason, "end_turn");
    assert.equal(await readFile(join(directory, "written.txt"), "utf8"), "written");
    assert.equal((await client.sessionPrompt({ sessionId: session.sessionId, prompt: "terminal" })).stopReason, "TERMINAL_OK");
  } finally {
    await client.stop();
    await rm(directory, { recursive: true, force: true });
  }
});

test("ACP terminal output truncates on a valid UTF-8 boundary and strips control environment", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-terminal-output-"));
  const previous = {
    token: process.env.ACP_GATEWAY_CONTROL_TOKEN,
    root: process.env.ACP_GATEWAY_ROOT_ID,
    socket: process.env.ACP_GATEWAY_SOCKET
  };
  process.env.ACP_GATEWAY_CONTROL_TOKEN = "PARENT_SECRET";
  process.env.ACP_GATEWAY_ROOT_ID = "PARENT_ROOT";
  process.env.ACP_GATEWAY_SOCKET = "/tmp/parent.sock";
  const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "auto_approve" });
  try {
    await client.start();
    const session = await client.sessionNew({ cwd: directory, permissionPolicy: "auto_approve" });
    const limited = JSON.parse((await client.sessionPrompt({ sessionId: session.sessionId, prompt: "terminal-unicode" })).stopReason);
    assert.equal(limited.truncated, true);
    assert.ok(Buffer.byteLength(limited.output) <= 16);
    assert.doesNotMatch(limited.output, /�/);
    assert.match(limited.output, /END$/);
    assert.equal((await client.sessionPrompt({ sessionId: session.sessionId, prompt: "terminal-split-unicode" })).stopReason, "😀");
    const env = JSON.parse((await client.sessionPrompt({ sessionId: session.sessionId, prompt: "terminal-env" })).stopReason);
    assert.equal(env.explicit, "VISIBLE");
    assert.equal(env.token, undefined);
    assert.equal(env.root, undefined);
    assert.equal(env.socket, undefined);
  } finally {
    await client.stop();
    for (const [name, value] of Object.entries({
      ACP_GATEWAY_CONTROL_TOKEN: previous.token,
      ACP_GATEWAY_ROOT_ID: previous.root,
      ACP_GATEWAY_SOCKET: previous.socket
    })) {
      if (value == null) delete process.env[name];
      else process.env[name] = value;
    }
    await rm(directory, { recursive: true, force: true });
  }
});

test("ACP operation grants cannot be spent on a different capability", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-grant-kind-"));
  const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "ask" });
  const permissions = [];
  try {
    await client.start();
    const session = await client.sessionNew({ cwd: directory, permissionPolicy: "ask" });
    client.onSessionUpdate(session.sessionId, (update) => {
      if (update.sessionUpdate === "permission_request") permissions.push(update);
    });
    const turn = client.sessionPrompt({ sessionId: session.sessionId, prompt: "edit-grant-then-terminal" });
    while (permissions.length < 1) await new Promise((done) => setImmediate(done));
    await client.respondPermission(permissions[0].requestId, "allow-once", session.sessionId);
    while (permissions.length < 2) await new Promise((done) => setImmediate(done));
    assert.equal(permissions[1].toolCall.kind, "execute");
    await client.respondPermission(permissions[1].requestId, "reject-once", session.sessionId);
    assert.equal((await turn).stopReason, "terminal-denied");
  } finally {
    await client.stop();
    await rm(directory, { recursive: true, force: true });
  }
});

test("ACP cancellation rejects a pending client operation", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-cancel-operation-"));
  const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "ask" });
  try {
    await client.start();
    const session = await client.sessionNew({ cwd: directory, permissionPolicy: "ask" });
    let permission;
    client.onSessionUpdate(session.sessionId, (update) => {
      if (update.sessionUpdate === "permission_request") permission = update;
    });
    const turn = client.sessionPrompt({ sessionId: session.sessionId, prompt: "write" });
    while (!permission) await new Promise((done) => setImmediate(done));
    client.cancelSession(session.sessionId);
    assert.equal((await turn).stopReason, "rejected");
    assert.equal(client.pendingOperations.size, 0);
  } finally {
    await client.stop();
    await rm(directory, { recursive: true, force: true });
  }
});

test("ACP ask gates direct writes and read-only rejects them", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-permission-"));
  try {
    for (const [policy, expected] of [["ask", "end_turn"], ["read_only", "rejected"]]) {
      const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "ask" });
      try {
        await client.start();
        const session = await client.sessionNew({ cwd: directory, permissionPolicy: policy });
        let permission;
        client.onSessionUpdate(session.sessionId, (update) => { if (update.sessionUpdate === "permission_request") permission = update; });
        const turn = client.sessionPrompt({ sessionId: session.sessionId, prompt: "write" });
        if (policy === "ask") {
          while (!permission) await new Promise((done) => setImmediate(done));
          await client.respondPermission(permission.requestId, "allow-once", session.sessionId);
        }
        assert.equal((await turn).stopReason, expected);
      } finally {
        await client.stop();
      }
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("ACP terminals are isolated between sessions", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-terminal-isolation-"));
  const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "auto_approve" });
  try {
    await client.start();
    const first = await client.sessionNew({ cwd: directory, permissionPolicy: "auto_approve" });
    const second = await client.sessionNew({ cwd: directory, permissionPolicy: "auto_approve" });
    assert.equal((await client.sessionPrompt({ sessionId: first.sessionId, prompt: "hold-terminal" })).stopReason, "holding");
    assert.equal((await client.sessionPrompt({ sessionId: second.sessionId, prompt: "cross-terminal" })).stopReason, "isolated");
    client.clearSession(first.sessionId);
  } finally {
    await client.stop();
    await rm(directory, { recursive: true, force: true });
  }
});

test("ACP writes cannot escape a session root through a symlink", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-symlink-"));
  const root = join(directory, "root");
  const outside = join(directory, "outside.txt");
  await mkdir(root);
  await writeFile(outside, "safe", "utf8");
  await symlink(outside, join(root, "written.txt"));
  const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "auto_approve" });
  try {
    await client.start();
    const session = await client.sessionNew({ cwd: root, permissionPolicy: "auto_approve" });
    assert.equal((await client.sessionPrompt({ sessionId: session.sessionId, prompt: "write" })).stopReason, "rejected");
    assert.equal(await readFile(outside, "utf8"), "safe");
  } finally {
    await client.stop();
    await rm(directory, { recursive: true, force: true });
  }
});

test("ACP cannot create a missing file through an external symlink parent", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-symlink-parent-"));
  const root = join(directory, "root");
  const outside = join(directory, "outside");
  await mkdir(root);
  await mkdir(outside);
  await symlink(outside, join(root, "external-parent"));
  const client = new AcpClient({ provider: "mock", command: process.execPath, args: [capabilityAgent], permissionPolicy: "auto_approve" });
  try {
    await client.start();
    const session = await client.sessionNew({ cwd: root, permissionPolicy: "auto_approve" });
    assert.equal(
      (await client.sessionPrompt({ sessionId: session.sessionId, prompt: "write-parent-symlink" })).stopReason,
      "rejected"
    );
    await assert.rejects(readFile(join(outside, "new.txt")), /ENOENT/);
  } finally {
    await client.stop();
    await rm(directory, { recursive: true, force: true });
  }
});
