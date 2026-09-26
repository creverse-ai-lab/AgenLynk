// Installs, reports and removes AgenLynk's monitoring hooks in the agents'
// own config: ~/.claude/settings.json, $CODEX_HOME/hooks.json and
// $GROK_HOME/hooks/agenlynk.json.
//
// Rules, because these files belong to the user and to other tools (Orca
// registers hooks in the same places):
// - only groups whose command runs agenlynk-hook.sh are ours; nothing else is
//   touched, reordered or reformatted beyond JSON re-serialization;
// - an existing group of ours is updated in place and a new one is appended,
//   so the position-keyed trust Codex records for other hooks stays valid;
// - a file that is not valid JSON is left alone and reported;
// - every file is backed up before its first change and written atomically;
// - Codex's trust (`[hooks.state]` in config.toml) is a security gate the user
//   answers in Codex (/hooks); it is reported, never written.

import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { agenlynkHome } from "./endpoint.js";

export const HOOKS_VERSION = 2;
// Bumped when what the hooks collect or where they are registered changes in
// a way the user should agree to again. A new script alone does not ask.
export const HOOKS_CONSENT_VERSION = 1;
const SCRIPT_NAME = "agenlynk-hook.sh";
const BUNDLED_SCRIPT = fileURLToPath(new URL("../../hooks/agenlynk-hook.sh", import.meta.url));
const HOOK_TIMEOUT_SECONDS = 5;

// Events each CLI is registered for. Claude and Codex lists are the events
// their current releases accept (the same sets other tools register on this
// machine); Grok's are from its bundled hooks guide.
const TARGETS = {
  claude: {
    home: (env) => env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"),
    file: (home) => join(home, "settings.json"),
    events: [
      "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
      "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop"
    ],
    matcherEvents: new Set(["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"]),
    matcher: "*"
  },
  codex: {
    home: (env) => env.CODEX_HOME || join(homedir(), ".codex"),
    file: (home) => join(home, "hooks.json"),
    events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "SubagentStart", "SubagentStop", "Stop"],
    matcherEvents: new Set(),
    trust: true
  },
  grok: {
    home: (env) => env.GROK_HOME || join(homedir(), ".grok"),
    file: (home) => join(home, "hooks", "agenlynk.json"),
    events: [
      "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
      "PermissionDenied", "Notification", "Stop", "StopFailure", "StopCancelled", "SubagentStart", "SubagentStop"
    ],
    matcherEvents: new Set(),
    ownsFile: true
  }
};

export const HOOK_PROVIDERS = Object.freeze(Object.keys(TARGETS));

function digest(text) {
  return createHash("sha256").update(text).digest("hex");
}

function bundledScript() {
  const source = readFileSync(BUNDLED_SCRIPT, "utf8");
  return { source, digest: digest(source) };
}

// The script lives under a directory named for its content, so a new script
// is a new command string: Codex, which trusts a hook by its definition,
// then asks the user again instead of silently running changed code.
function paths(env) {
  const home = agenlynkHome(env);
  return {
    home,
    scriptsRoot: join(home, "hooks"),
    script: join(home, "hooks", bundledScript().digest.slice(0, 12), SCRIPT_NAME),
    state: join(home, "hooks-state.json"),
    backups: join(home, "backups")
  };
}

function quote(path) {
  return `'${path.replaceAll("'", "'\\''")}'`;
}

function hookCommand(script, provider) {
  // Same guard shape other tools use: a removed script degrades to a no-op
  // that still drains stdin instead of failing the agent's hook run.
  return `if [ -r ${quote(script)} ]; then /bin/sh ${quote(script)} ${provider}; else cat >/dev/null 2>&1 || :; fi`;
}

function isOurs(group) {
  return Array.isArray(group?.hooks) && group.hooks.some((hook) => typeof hook?.command === "string" && hook.command.includes(SCRIPT_NAME));
}

function ourGroup(target, event, script, provider) {
  return {
    ...(target.matcherEvents.has(event) ? { matcher: target.matcher } : {}),
    hooks: [{ type: "command", command: hookCommand(script, provider), timeout: HOOK_TIMEOUT_SECONDS }]
  };
}

function readJson(path) {
  if (!existsSync(path)) return { exists: false, value: {} };
  const text = readFileSync(path, "utf8");
  if (!text.trim()) return { exists: true, value: {}, text };
  try {
    const value = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value)) return { exists: true, error: "not a JSON object", text };
    return { exists: true, value, text };
  } catch (error) {
    return { exists: true, error: `invalid JSON (${error.message})`, text };
  }
}

function writeJsonAtomic(path, value, previousMode) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.agenlynk.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: previousMode ?? 0o600 });
  renameSync(temporary, path);
}

function backup(path, backups, now) {
  if (!existsSync(path)) return null;
  mkdirSync(backups, { recursive: true, mode: 0o700 });
  const stamp = new Date(now).toISOString().replace(/[:.]/g, "-");
  const target = join(backups, `${basename(dirname(path))}-${basename(path)}.${stamp}.bak`);
  copyFileSync(path, target);
  return target;
}

/** Hooks object with ours set for every event (updated in place, else appended). */
function withOurHooks(hooks, target, script, provider) {
  const next = { ...(hooks && typeof hooks === "object" && !Array.isArray(hooks) ? hooks : {}) };
  for (const event of target.events) {
    const groups = Array.isArray(next[event]) ? [...next[event]] : [];
    const index = groups.findIndex(isOurs);
    const group = ourGroup(target, event, script, provider);
    if (index >= 0) groups[index] = group;
    else groups.push(group);
    next[event] = groups;
  }
  return next;
}

function withoutOurHooks(hooks) {
  const next = {};
  for (const [event, groups] of Object.entries(hooks && typeof hooks === "object" ? hooks : {})) {
    if (!Array.isArray(groups)) {
      next[event] = groups;
      continue;
    }
    const kept = groups.filter((group) => !isOurs(group));
    if (kept.length) next[event] = kept;
  }
  return next;
}

function snake(event) {
  return event.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase();
}

// `[hooks.state."<hooks.json>:<event>:<group>:<hook>"]` + `trusted_hash`,
// as Codex writes them after /hooks approval.
function readCodexTrust(codexHome) {
  let config = "";
  try {
    config = readFileSync(join(codexHome, "config.toml"), "utf8");
  } catch {
    return new Map();
  }
  const trust = new Map();
  const pattern = /^\[hooks\.state\."([^"]+)"\]\s*\n(?:[^\[]*?)trusted_hash\s*=\s*"([^"]*)"/gm;
  for (const match of config.matchAll(pattern)) trust.set(match[1], match[2]);
  return trust;
}

function ourCodexKeys(hooksFile, hooks) {
  const keys = new Map();
  for (const [event, groups] of Object.entries(hooks ?? {})) {
    if (!Array.isArray(groups)) continue;
    const index = groups.findIndex(isOurs);
    if (index >= 0) keys.set(event, `${hooksFile}:${snake(event)}:${index}:0`);
  }
  return keys;
}

/**
 * Codex events whose current AgenLynk hook the user has not approved. An
 * approval recorded before our last change to that hook (same trusted_hash as
 * when we wrote it) belongs to the old definition and does not count.
 */
function untrustedCodexEvents(hooksFile, hooks, codexHome, staleTrust = {}) {
  const trust = readCodexTrust(codexHome);
  const pending = [];
  for (const [event, key] of ourCodexKeys(hooksFile, hooks)) {
    const hash = trust.get(key);
    if (hash == null || (Object.hasOwn(staleTrust, key) && staleTrust[key] === hash)) pending.push(event);
  }
  return pending;
}

function installScript(scriptPath, scriptsRoot) {
  const { source } = bundledScript();
  let current = null;
  try {
    current = readFileSync(scriptPath, "utf8");
  } catch {
    // Not installed yet.
  }
  if (current !== source) {
    mkdirSync(dirname(scriptPath), { recursive: true, mode: 0o700 });
    const temporary = `${scriptPath}.${process.pid}.tmp`;
    writeFileSync(temporary, source, { mode: 0o755 });
    renameSync(temporary, scriptPath);
  }
  // Older versions are only referenced by configs this install just
  // rewrote; a config still naming one degrades to the command's no-op guard.
  const version = basename(dirname(scriptPath));
  try {
    for (const entry of readdirSync(scriptsRoot, { withFileTypes: true })) {
      if (entry.name === version) continue;
      rmSync(join(scriptsRoot, entry.name), { recursive: true, force: true });
    }
  } catch {
    // Nothing to prune.
  }
  return digest(source);
}

export function readHookState(env = process.env) {
  try {
    return JSON.parse(readFileSync(paths(env).state, "utf8"));
  } catch {
    return null;
  }
}

function writeHookState(env, state) {
  const { state: path } = paths(env);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, path);
}

function selectedProviders(only) {
  return (only?.length ? only : HOOK_PROVIDERS).filter((provider) => TARGETS[provider]);
}

/** Per-CLI hook status, read from the agents' own files. */
export function hookStatus({ env = process.env, only = null } = {}) {
  const { script } = paths(env);
  const state = readHookState(env);
  const targets = {};
  for (const provider of selectedProviders(only)) {
    const target = TARGETS[provider];
    const home = target.home(env);
    const file = target.file(home);
    const present = existsSync(home);
    const parsed = readJson(file);
    const hooks = parsed.value?.hooks;
    const installedEvents = parsed.error ? [] : target.events.filter((event) => Array.isArray(hooks?.[event]) && hooks[event].some(isOurs));
    const entry = {
      agentPresent: present,
      disabled: (state?.disabledProviders ?? []).includes(provider),
      file,
      installed: installedEvents.length === target.events.length,
      partial: installedEvents.length > 0 && installedEvents.length < target.events.length,
      events: installedEvents
    };
    if (parsed.error) entry.error = parsed.error;
    if (target.trust && installedEvents.length) {
      const pending = untrustedCodexEvents(file, hooks, home, state?.codexStaleTrust ?? {});
      entry.needsTrust = pending.length > 0;
      entry.untrustedEvents = pending;
    }
    targets[provider] = entry;
  }
  const consented = (state?.consent?.version ?? 0) >= HOOKS_CONSENT_VERSION;
  return {
    version: HOOKS_VERSION,
    enabled: state?.enabled !== false,
    // The app asks before the first install and after a consent bump; a user
    // who declined is not asked again until the scope changes.
    consentRequired: !consented && state?.declinedConsentVersion !== HOOKS_CONSENT_VERSION,
    consentVersion: HOOKS_CONSENT_VERSION,
    script,
    scriptInstalled: existsSync(script),
    installedVersion: state?.version ?? null,
    targets
  };
}

/**
 * Installs (or refreshes) hooks for every CLI present on this machine, or the
 * ones in `only`. Returns the resulting status plus what was changed.
 */
export function installHooks({ env = process.env, only = null, now = Date.now(), consent = false } = {}) {
  const locations = paths(env);
  const scriptDigest = installScript(locations.script, locations.scriptsRoot);
  const changes = [];
  const errors = {};
  const previousState = readHookState(env);
  let codexStaleTrust = previousState?.codexStaleTrust ?? {};
  for (const provider of selectedProviders(only)) {
    const target = TARGETS[provider];
    const home = target.home(env);
    if (!existsSync(home)) continue;
    const file = target.file(home);
    const parsed = readJson(file);
    if (parsed.error) {
      errors[provider] = `${file}: ${parsed.error}; left unchanged`;
      continue;
    }
    const nextHooks = withOurHooks(parsed.value.hooks, target, locations.script, provider);
    const next = { ...parsed.value, hooks: nextHooks };
    if (JSON.stringify(next) === JSON.stringify(parsed.value)) continue;
    const mode = parsed.exists ? statSync(file).mode & 0o777 : undefined;
    const saved = backup(file, locations.backups, now);
    writeJsonAtomic(file, next, mode);
    changes.push({ provider, file, backup: saved });
    if (target.trust) {
      // Whatever Codex trusted for these positions was the old definition.
      const trust = readCodexTrust(home);
      codexStaleTrust = {};
      for (const key of ourCodexKeys(file, nextHooks).values()) {
        if (trust.has(key)) codexStaleTrust[key] = trust.get(key);
      }
    }
  }
  const previous = previousState;
  const installed = new Set(selectedProviders(only));
  writeHookState(env, {
    version: HOOKS_VERSION,
    enabled: true,
    codexStaleTrust,
    consent: consent
      ? { version: HOOKS_CONSENT_VERSION, at: new Date(now).toISOString() }
      : previous?.consent ?? null,
    // Turning one CLI back on clears only its opt-out.
    disabledProviders: (previous?.disabledProviders ?? []).filter((provider) => !installed.has(provider)),
    scriptDigest,
    installedAt: previous?.installedAt ?? new Date(now).toISOString(),
    updatedAt: new Date(now).toISOString()
  });
  return { ...hookStatus({ env, only }), changes, errors };
}

/** Removes AgenLynk's hooks (and nothing else) and remembers the choice. */
export function uninstallHooks({ env = process.env, only = null, now = Date.now(), decline = false } = {}) {
  const locations = paths(env);
  const changes = [];
  const errors = {};
  for (const provider of selectedProviders(only)) {
    const target = TARGETS[provider];
    const file = target.file(target.home(env));
    const parsed = readJson(file);
    if (!parsed.exists) continue;
    if (parsed.error) {
      errors[provider] = `${file}: ${parsed.error}; left unchanged`;
      continue;
    }
    const hooks = withoutOurHooks(parsed.value.hooks);
    if (JSON.stringify(hooks) === JSON.stringify(parsed.value.hooks ?? {})) continue;
    const saved = backup(file, locations.backups, now);
    const rest = { ...parsed.value };
    delete rest.hooks;
    if (target.ownsFile && !Object.keys(hooks).length && !Object.keys(rest).length) {
      rmSync(file, { force: true });
    } else {
      writeJsonAtomic(file, Object.keys(hooks).length ? { ...rest, hooks } : rest, statSync(file).mode & 0o777);
    }
    changes.push({ provider, file, backup: saved });
  }
  const previous = readHookState(env);
  writeHookState(env, {
    ...(previous ?? {}),
    version: HOOKS_VERSION,
    // Removing every CLI's hooks turns the feature off; removing one CLI's
    // records an opt-out so the next start does not put it back.
    enabled: only?.length ? previous?.enabled !== false : false,
    disabledProviders: only?.length
      ? [...new Set([...(previous?.disabledProviders ?? []), ...selectedProviders(only)])]
      : previous?.disabledProviders ?? [],
    ...(decline ? { declinedConsentVersion: HOOKS_CONSENT_VERSION } : {}),
    updatedAt: new Date(now).toISOString()
  });
  return { ...hookStatus({ env, only }), changes, errors };
}

/**
 * The install-on-start policy: refresh hooks when this build ships a newer
 * hook version or script, unless the user turned them off.
 */
export function ensureHooks({ env = process.env, now = Date.now() } = {}) {
  const state = readHookState(env);
  if (state?.enabled === false) return { skipped: "disabled" };
  // Nothing is written to the user's agent configs before they agreed.
  if ((state?.consent?.version ?? 0) < HOOKS_CONSENT_VERSION) return { skipped: "consent_required" };
  const bundled = bundledScript().digest;
  const wanted = HOOK_PROVIDERS.filter((provider) => !(state?.disabledProviders ?? []).includes(provider));
  // An empty `only` means "every CLI" to the helpers below.
  if (!wanted.length) return { skipped: "disabled" };
  const status = hookStatus({ env, only: wanted });
  const complete = Object.values(status.targets).every((target) => !target.agentPresent || target.installed || target.error);
  if (state?.version === HOOKS_VERSION && state?.scriptDigest === bundled && status.scriptInstalled && complete) {
    return { skipped: "current" };
  }
  return installHooks({ env, only: wanted, now });
}
