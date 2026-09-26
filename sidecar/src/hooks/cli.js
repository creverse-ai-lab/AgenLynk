#!/usr/bin/env node
// Manual entry point for AgenLynk's monitoring hooks:
//   node sidecar/src/hooks/cli.js status|install|uninstall [--only claude,codex,grok]
// Prints the resulting status as JSON. The app normally does this through
// the sidecar (/api/hooks); this is for support and scripting.

import { hookStatus, installHooks, uninstallHooks, HOOK_PROVIDERS } from "./installer.js";

const [command = "status", ...rest] = process.argv.slice(2);
const onlyIndex = rest.indexOf("--only");
const only = onlyIndex >= 0
  ? (rest[onlyIndex + 1] ?? "").split(",").map((value) => value.trim()).filter((value) => HOOK_PROVIDERS.includes(value))
  : null;

const actions = { status: hookStatus, install: installHooks, uninstall: uninstallHooks };
const action = actions[command];
if (!action) {
  console.error("usage: cli.js status|install|uninstall [--only claude,codex,grok]");
  process.exit(2);
}
console.log(JSON.stringify(action({ only: only?.length ? only : null }), null, 2));
