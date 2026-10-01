// Which agents already have the "agent-acp" Control MCP installed, and whether
// each registered entry still launches the runtime this app keeps current.
//
// The ground truth is each agent's own config, NOT install.json's managedMcp
// record — managedMcp only lists what this app installed, so an MCP the user
// set up any other way (or before this app tracked it) would read as "not
// installed" and be wrongly offered for install. The section header
// `[mcp_servers.agent-acp]` (codex/grok TOML) or the `mcpServers["agent-acp"]`
// key (claude/auggie JSON) is what actually gates the Frontdoor.
//
// Presence alone is not enough: an entry pinned to
// runtime/versions/<old>/ keeps launching that old Gateway after every
// activation, so it is reported as stale for Settings to relink.

import { readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join, sep } from "node:path";

const FRONT_DOOR_AGENTS = new Set(["codex", "claude", "grok"]);
const CONTROL = "agent-acp";
const GUIDE = "agent-acp-guide";

/** The `[mcp_servers.<name>]` table of a TOML config, or null. */
export function tomlServer(text, name) {
  const lines = text.split(/\r?\n/);
  const header = new RegExp(`^\\s*\\[mcp_servers\\.(?:"${name}"|${name})\\]\\s*(?:#.*)?$`);
  const start = lines.findIndex((line) => header.test(line));
  if (start < 0) return null;
  let end = lines.findIndex((line, index) => index > start && /^\s*\[/.test(line));
  if (end < 0) end = lines.length;
  const body = lines.slice(start + 1, end).join("\n");
  const command = /^\s*command\s*=\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')/m.exec(body);
  const args = /^\s*args\s*=\s*\[([\s\S]*?)\]/m.exec(body);
  return {
    command: command ? command[1] ?? command[2] : null,
    args: args ? [...args[1].matchAll(/"((?:[^"\\]|\\.)*)"|'([^']*)'/g)].map((match) => match[1] ?? match[2]) : []
  };
}

async function tomlServers(path) {
  try {
    const text = await readFile(path, "utf8");
    return { control: tomlServer(text, CONTROL), guide: tomlServer(text, GUIDE) };
  } catch {
    return { control: null, guide: null };
  }
}

async function jsonServers(path) {
  try {
    const servers = JSON.parse(await readFile(path, "utf8"))?.mcpServers ?? {};
    const entry = (value) => (value && typeof value === "object"
      ? { command: typeof value.command === "string" ? value.command : null, args: Array.isArray(value.args) ? value.args.map(String) : [] }
      : null);
    return { control: entry(servers[CONTROL]), guide: entry(servers[GUIDE]) };
  } catch {
    return { control: null, guide: null };
  }
}

/** The version directory `runtime/current` points at now, or null. */
async function currentRuntimeId(gatewayHome) {
  try {
    const pointer = JSON.parse(await readFile(join(gatewayHome, "runtime", "current.json"), "utf8"));
    const root = typeof pointer?.runtimeRoot === "string" ? pointer.runtimeRoot : "";
    return root.split(sep).filter(Boolean).at(-1) ?? null;
  } catch {
    return null;
  }
}

/**
 * Why an entry no longer launches the current runtime, or null when it does
 * (or is not this app's to judge: an npm-global or dev-checkout Gateway the
 * user registered by hand).
 * - "pinned": its script sits under runtime/versions/<id>/ of a version that
 *   is no longer current, so it keeps launching that old Gateway.
 * - "missing": it points into this app's runtime, at a script that is gone.
 */
export async function staleReason(entry, gatewayHome, currentId) {
  const script = entry?.args?.find((arg) => /\.(?:m?js)$/.test(arg));
  if (!script) return null;
  const runtime = join(gatewayHome, "runtime") + sep;
  if (!script.startsWith(runtime)) return null;
  let resolved;
  try {
    resolved = await realpath(script);
  } catch {
    return { reason: "missing", path: script };
  }
  const [area, id] = script.slice(runtime.length).split(sep);
  // A version path that resolves into the current version (a hand-made
  // alias) still launches the current runtime.
  const current = currentId ? await realpath(join(runtime, "versions", currentId)).catch(() => null) : null;
  if (current && resolved.startsWith(current + sep)) return null;
  if (area === "versions" && id && currentId && id !== currentId) {
    return { reason: "pinned", path: script, version: id };
  }
  return null;
}

export async function readInstalledFrontdoors({
  home = homedir(),
  gatewayHome = join(home, ".acp-gateway"),
  codexHome = process.env.CODEX_HOME || join(home, ".codex"),
  grokHome = process.env.GROK_HOME || join(home, ".grok"),
  augmentHome = process.env.AUGMENT_HOME || join(home, ".augment"),
  installStatePath = join(gatewayHome, "install.json")
} = {}) {
  const [codex, claude, grok, auggie, currentId] = await Promise.all([
    tomlServers(join(codexHome, "config.toml")),
    jsonServers(join(home, ".claude.json")),
    tomlServers(join(grokHome, "config.toml")),
    // Auggie takes the guide from the Gateway installer like the others.
    jsonServers(join(augmentHome, "settings.json")),
    currentRuntimeId(gatewayHome)
  ]);
  const agents = { codex, claude, grok, auggie };
  const frontdoors = Object.keys(agents).filter((agent) => FRONT_DOOR_AGENTS.has(agent));
  const installed = frontdoors.filter((agent) => agents[agent].control);
  // Only the guide MCP: the agent can read how to delegate but is not a
  // Frontdoor, so Settings must not show it as installed nor as untouched.
  const guideOnly = frontdoors.filter((agent) => agents[agent].guide && !agents[agent].control);
  const stale = [];
  for (const [agent, servers] of Object.entries(agents)) {
    for (const [kind, entry] of [["control", servers.control], ["guide", servers.guide]]) {
      const found = entry ? await staleReason(entry, gatewayHome, currentId) : null;
      if (found) stale.push({ agent, entry: kind, ...found });
    }
  }
  // The exclusive primary is still whatever install.json recorded; it is only
  // a label, and a missing/invalid file just means "no primary".
  let primary = null;
  try {
    const raw = JSON.parse(await readFile(installStatePath, "utf8"));
    if (FRONT_DOOR_AGENTS.has(raw?.frontDoor)) primary = raw.frontDoor;
  } catch {
    // no install.json → no primary
  }
  return { primary, installed, guideOnly, stale };
}
