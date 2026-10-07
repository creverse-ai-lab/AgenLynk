// The agent-delegator skill AgenLynk ships to every Main CLI.
//
// The skill tells a Main how to call the ACP Gateway; a copy that falls behind
// the Gateway it drives (a 1.4-era copy against 1.7) gives wrong instructions,
// and nothing else refreshes it after the first install. So each sidecar start
// brings every installed copy up to the one this build ships, the same way it
// refreshes its hooks.
//
// A copy is replaced only when it is provably nobody's edit: its tree digest
// equals what AgenLynk last wrote, or what the Gateway installer recorded
// writing (`managedSkills[<agent>:agent-delegator].sourceDigest` in
// install.json; the digest below is computed the same way). Anything else is
// a user's customization and stays until they choose to replace it.

import { createHash } from "node:crypto";
import { cp, lstat, mkdir, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { agenlynkHome } from "../hooks/endpoint.js";
import { defaultInstallStatePath } from "./install-state.js";

export const SKILL_NAME = "agent-delegator";
export const SKILL_AGENTS = ["claude", "codex", "grok", "auggie"];
const DEFAULT_SOURCE = fileURLToPath(new URL(`../../skills/${SKILL_NAME}`, import.meta.url));

/** Where each agent keeps its skills, and the home whose presence means the CLI is set up. */
export function skillTargets(env = process.env, home = homedir()) {
  const homes = {
    claude: join(home, ".claude"),
    codex: env.CODEX_HOME || join(home, ".codex"),
    grok: env.GROK_HOME || join(home, ".grok"),
    auggie: env.AUGMENT_HOME || join(home, ".augment")
  };
  return SKILL_AGENTS.map((agent) => ({ agent, home: homes[agent], path: join(homes[agent], "skills", SKILL_NAME) }));
}

/** sha256 over the tree, entry by entry in name order (the Gateway installer's skillTreeDigest). */
export async function skillTreeDigest(root) {
  const hash = createHash("sha256");
  const absoluteRoot = resolve(root);
  const rootStat = await lstat(absoluteRoot);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error(`skill root must be a real directory: ${absoluteRoot}`);
  async function visit(directory, prefix = "") {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));
    for (const entry of entries) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        hash.update(`directory\0${relative}\0`);
        await visit(path, relative);
      } else if (entry.isFile()) {
        const data = await readFile(path);
        hash.update(`file\0${relative}\0${data.length}\0`);
        hash.update(data);
      } else {
        throw new Error(`unsupported skill entry: ${path}`);
      }
    }
  }
  await visit(absoluteRoot);
  return hash.digest("hex");
}

async function readJson(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return null;
  }
}

async function exists(path) {
  try {
    await lstat(path);
    return true;
  } catch {
    return false;
  }
}

function defaultOptions(options = {}) {
  return {
    source: options.source ?? DEFAULT_SOURCE,
    targets: options.targets ?? skillTargets(),
    recordPath: options.recordPath ?? join(agenlynkHome(), "skills.json"),
    gatewayStatePath: options.gatewayStatePath
      ?? defaultInstallStatePath()
  };
}

/**
 * Per agent whose CLI is set up: "current" (same as shipped), "outdated" (an
 * unedited older copy, replaced automatically), "customized" (edited, left
 * alone), or "missing".
 */
export async function delegatorSkillStatus(options) {
  const { source, targets, recordPath, gatewayStatePath } = defaultOptions(options);
  const shipped = await skillTreeDigest(source);
  const record = (await readJson(recordPath))?.skills ?? {};
  const gatewaySkills = (await readJson(gatewayStatePath))?.managedSkills ?? {};
  const results = [];
  for (const target of targets) {
    if (!(await exists(target.home))) continue;
    let state;
    let digest = null;
    if (!(await exists(target.path))) {
      state = "missing";
    } else {
      try {
        digest = await skillTreeDigest(target.path);
      } catch {
        digest = null;
      }
      const owned = [record[target.agent]?.digest, gatewaySkills[`${target.agent}:${SKILL_NAME}`]?.sourceDigest];
      state = digest === shipped ? "current" : digest && owned.includes(digest) ? "outdated" : "customized";
    }
    results.push({ agent: target.agent, path: target.path, state });
  }
  return { name: SKILL_NAME, digest: shipped, targets: results };
}

/** Copies the shipped tree over `path` through a sibling, so a reader never sees half a skill. */
async function replaceTree(source, path) {
  await mkdir(dirname(path), { recursive: true });
  const staging = `${path}.agenlynk-${process.pid}-new`;
  const previous = `${path}.agenlynk-${process.pid}-old`;
  await rm(staging, { recursive: true, force: true });
  await cp(source, staging, { recursive: true });
  const hadPrevious = await exists(path);
  if (hadPrevious) await rename(path, previous);
  try {
    await rename(staging, path);
  } catch (error) {
    if (hadPrevious) await rename(previous, path).catch(() => {});
    throw error;
  }
  if (hadPrevious) await rm(previous, { recursive: true, force: true });
}

/**
 * Brings copies up to the shipped skill. By default only "outdated" ones;
 * `install` also adds it where it is missing, and `force` lists the agents
 * whose customized copy the user chose to replace.
 */
export async function syncDelegatorSkill(options = {}) {
  const resolved = defaultOptions(options);
  const { install = [], force = [] } = options;
  const status = await delegatorSkillStatus(resolved);
  const record = (await readJson(resolved.recordPath)) ?? { version: 1, skills: {} };
  record.skills ??= {};
  const updated = [];
  const errors = {};
  for (const target of status.targets) {
    const wanted = target.state === "outdated"
      || (target.state === "missing" && install.includes(target.agent))
      || (target.state === "customized" && force.includes(target.agent));
    if (!wanted) continue;
    try {
      await replaceTree(resolved.source, target.path);
      record.skills[target.agent] = { path: target.path, digest: status.digest, updatedAt: new Date().toISOString() };
      updated.push(target.agent);
    } catch (error) {
      errors[target.agent] = error.message;
    }
  }
  if (updated.length) {
    await mkdir(dirname(resolved.recordPath), { recursive: true });
    await writeFile(resolved.recordPath, `${JSON.stringify(record, null, 2)}\n`);
  }
  return { ...(await delegatorSkillStatus(resolved)), updated, errors };
}
