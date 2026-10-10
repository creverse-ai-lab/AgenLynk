import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { frontDoorReadsInstallState, readInstalledFrontdoors, tomlServer } from "../src/app/frontdoor-configs.js";

test("a TOML server table yields its command and args, not a sibling's", () => {
  const text = [
    "[mcp_servers.agent-acp-guide]",
    'command = "/node"',
    'args = ["/guide.js"]',
    "",
    "[mcp_servers.agent-acp]",
    'command = "/current/node"',
    "args = [",
    '  "/current/index.js"',
    "]",
    "  [mcp_servers.agent-acp.env]",
    '  ACP_GATEWAY_ROOT_ID = "main"'
  ].join("\n");
  assert.deepEqual(tomlServer(text, "agent-acp"), { command: "/current/node", args: ["/current/index.js"], envNames: ["ACP_GATEWAY_ROOT_ID"] });
  assert.deepEqual(tomlServer(text, "agent-acp-guide"), { command: "/node", args: ["/guide.js"], envNames: [] });
  assert.equal(tomlServer(text, "other"), null);
});

// Regression: Settings only checked that a control section existed, so a
// Codex entry still pinned to runtime/versions/1.4.0 read as installed and
// kept launching the 1.4.0 Gateway after every update.
test("entries pinned to an old runtime version are reported stale", async () => {
  const home = await mkdtemp(join(tmpdir(), "frontdoor-configs-"));
  try {
    const gatewayHome = join(home, ".acp-gateway");
    const runtime = join(gatewayHome, "runtime");
    const script = (version, name) => join(runtime, "versions", version, "gateway", "src", name);
    for (const version of ["1.4.0-old", "1.6.0-new"]) {
      await mkdir(join(runtime, "versions", version, "gateway", "src"), { recursive: true });
      for (const name of ["index.js", "guide.js"]) await writeFile(script(version, name), "");
    }
    await mkdir(join(runtime, "current", "gateway", "src"), { recursive: true });
    for (const name of ["index.js", "guide.js"]) await writeFile(join(runtime, "current", "gateway", "src", name), "");
    await writeFile(join(runtime, "current.json"), JSON.stringify({ runtimeRoot: join(runtime, "versions", "1.6.0-new") }));

    await mkdir(join(home, ".codex"), { recursive: true });
    await writeFile(join(home, ".codex", "config.toml"), [
      "[mcp_servers.agent-acp]",
      'command = "/node"',
      `args = ["${script("1.4.0-old", "index.js")}"]`,
      "[mcp_servers.agent-acp-guide]",
      'command = "/node"',
      `args = ["${join(runtime, "current", "gateway", "src", "guide.js")}"]`
    ].join("\n"));
    await writeFile(join(home, ".claude.json"), JSON.stringify({ mcpServers: {
      "agent-acp": { command: "/node", args: [script("1.6.0-new", "index.js")], env: { ACP_GATEWAY_CONTROL_TOKEN: "t" } },
      "agent-acp-guide": { command: "/node", args: [script("1.4.0-old", "guide.js")] }
    } }));
    await mkdir(join(home, ".augment"), { recursive: true });
    await writeFile(join(home, ".augment", "settings.json"), JSON.stringify({ mcpServers: {
      "agent-acp-guide": { command: "/node", args: [join(runtime, "versions", "1.3.0-gone", "gateway", "src", "guide.js")] }
    } }));
    await mkdir(join(home, ".grok"), { recursive: true });
    // A Gateway the user runs from their own checkout is not this app's to judge.
    await writeFile(join(home, ".grok", "config.toml"), '[mcp_servers.agent-acp]\ncommand = "node"\nargs = ["/src/agent_gateway/src/index.js"]\n');

    const result = await readInstalledFrontdoors({
      home, gatewayHome, codexHome: join(home, ".codex"), grokHome: join(home, ".grok"), augmentHome: join(home, ".augment")
    });
    assert.deepEqual(result.installed, ["codex", "claude", "grok"]);
    assert.deepEqual(result.stale.map(({ agent, entry, reason, version }) => ({ agent, entry, reason, version })), [
      { agent: "codex", entry: "control", reason: "pinned", version: "1.4.0-old" },
      { agent: "claude", entry: "guide", reason: "pinned", version: "1.4.0-old" },
      { agent: "auggie", entry: "guide", reason: "missing", version: undefined }
    ]);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("a TOML server's env names come from its env table, an inline table, or dotted keys, never its values", () => {
  const table = '[mcp_servers.agent-acp]\nargs = ["/i.js"]\n\n  [mcp_servers.agent-acp.env]\n  ACP_GATEWAY_CONTROL_TOKEN = "secret"\n  "PATH" = "/bin"\n[other]\nX = 1\n';
  assert.deepEqual(tomlServer(table, "agent-acp").envNames, ["ACP_GATEWAY_CONTROL_TOKEN", "PATH"]);
  const inline = '[mcp_servers.agent-acp]\nargs = ["/i.js"]\nenv = { ACP_GATEWAY_ROOT_ID = "r", "ACP_GATEWAY_CONTROL_TOKEN" = "t" }\nenv.EXTRA = "1"\n';
  assert.deepEqual(tomlServer(inline, "agent-acp").envNames, ["ACP_GATEWAY_ROOT_ID", "ACP_GATEWAY_CONTROL_TOKEN", "EXTRA"]);
  assert.ok(!JSON.stringify(tomlServer(table, "agent-acp")).includes("secret"));
});

test("the token-free front door starts with Gateway 1.8.0", () => {
  assert.equal(frontDoorReadsInstallState("1.8.0"), true);
  assert.equal(frontDoorReadsInstallState("1.10.0"), true);
  assert.equal(frontDoorReadsInstallState("2.0.0-beta"), true);
  assert.equal(frontDoorReadsInstallState("1.7.2"), false);
  assert.equal(frontDoorReadsInstallState("dev"), null);
});

// Gateway 1.8 takes the Control token out of agent configs; an entry that
// still holds it should be relinked, and after a rollback below 1.8 one
// without it cannot start.
async function controlEntries(version, entries) {
  const home = await mkdtemp(join(tmpdir(), "frontdoor-token-"));
  const gatewayHome = join(home, ".acp-gateway");
  const runtime = join(gatewayHome, "runtime");
  const index = join(runtime, "current", "gateway", "src", "index.js");
  await mkdir(join(runtime, "current", "gateway", "src"), { recursive: true });
  await writeFile(index, "");
  await writeFile(join(runtime, "current.json"), JSON.stringify({ runtimeRoot: join(runtime, "versions", `${version}-abc`), gatewayVersion: version }));
  await mkdir(join(home, ".codex"), { recursive: true });
  await writeFile(join(home, ".codex", "config.toml"), [
    "[mcp_servers.agent-acp]", 'command = "/node"', `args = ["${index}"]`,
    ...(entries.codex ? ["[mcp_servers.agent-acp.env]", 'ACP_GATEWAY_CONTROL_TOKEN = "t"'] : [])
  ].join("\n"));
  await writeFile(join(home, ".claude.json"), JSON.stringify({ mcpServers: {
    "agent-acp": { command: "/node", args: [index], ...(entries.claude ? { env: { ACP_GATEWAY_CONTROL_TOKEN: "t" } } : {}) },
    "agent-acp-guide": { command: "/node", args: [join(runtime, "current", "gateway", "src", "index.js")] }
  } }));
  await mkdir(join(home, ".grok"), { recursive: true });
  // The user's own Gateway checkout keeps whatever env it needs.
  await writeFile(join(home, ".grok", "config.toml"), '[mcp_servers.agent-acp]\ncommand = "node"\nargs = ["/src/agent_gateway/src/index.js"]\n[mcp_servers.agent-acp.env]\nACP_GATEWAY_CONTROL_TOKEN = "t"\n');
  try {
    const result = await readInstalledFrontdoors({
      home, gatewayHome, codexHome: join(home, ".codex"), grokHome: join(home, ".grok"), augmentHome: join(home, ".augment")
    });
    return result.stale.map(({ agent, entry, reason }) => ({ agent, entry, reason }));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

test("on Gateway 1.8 a Control entry that still holds the token is relinked", async () => {
  assert.deepEqual(await controlEntries("1.8.0", { codex: true, claude: false }), [
    { agent: "codex", entry: "control", reason: "token" }
  ]);
});

test("below Gateway 1.8 a Control entry without the token is relinked", async () => {
  assert.deepEqual(await controlEntries("1.7.2", { codex: true, claude: false }), [
    { agent: "claude", entry: "control", reason: "needs-token" }
  ]);
});
