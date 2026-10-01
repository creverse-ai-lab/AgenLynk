import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { readInstalledFrontdoors, tomlServer } from "../src/app/frontdoor-configs.js";

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
  assert.deepEqual(tomlServer(text, "agent-acp"), { command: "/current/node", args: ["/current/index.js"] });
  assert.deepEqual(tomlServer(text, "agent-acp-guide"), { command: "/node", args: ["/guide.js"] });
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
      "agent-acp": { command: "/node", args: [script("1.6.0-new", "index.js")] },
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
