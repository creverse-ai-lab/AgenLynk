import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { delegatorSkillStatus, skillTreeDigest, syncDelegatorSkill } from "../src/app/delegator-skill.js";

async function writeSkill(root, text) {
  await mkdir(join(root, "references"), { recursive: true });
  await writeFile(join(root, "SKILL.md"), text);
  await writeFile(join(root, "references", "recovery.md"), "retry with the taskId\n");
}

// Regression: the skill was installed once and never refreshed, so every Main
// kept 1.4-era instructions against a newer Gateway.
test("unedited skill copies follow the shipped one; edited copies stay unless forced", async () => {
  const root = await mkdtemp(join(tmpdir(), "delegator-skill-"));
  try {
    const source = join(root, "ship", "agent-delegator");
    await writeSkill(source, "new instructions\n");
    const target = (agent) => ({ agent, home: join(root, agent), path: join(root, agent, "skills", "agent-delegator") });
    const targets = ["claude", "codex", "grok", "auggie"].map(target);
    // claude: the Gateway installer's unedited copy; codex: what AgenLynk
    // wrote before; grok: edited by the user; auggie: CLI not set up.
    await writeSkill(targets[0].path, "old gateway instructions\n");
    await writeSkill(targets[1].path, "older agenlynk instructions\n");
    await writeSkill(targets[2].path, "my own instructions\n");
    const gatewayStatePath = join(root, "install.json");
    await writeFile(gatewayStatePath, JSON.stringify({ managedSkills: {
      "claude:agent-delegator": { sourceDigest: await skillTreeDigest(targets[0].path) },
      "grok:agent-delegator": { sourceDigest: "an-older-digest" }
    } }));
    const recordPath = join(root, "agenlynk", "skills.json");
    await mkdir(join(root, "agenlynk"), { recursive: true });
    await writeFile(recordPath, JSON.stringify({ version: 1, skills: { codex: { digest: await skillTreeDigest(targets[1].path) } } }));
    const options = { source, targets, recordPath, gatewayStatePath };

    const before = await delegatorSkillStatus(options);
    assert.deepEqual(before.targets.map(({ agent, state }) => [agent, state]),
      [["claude", "outdated"], ["codex", "outdated"], ["grok", "customized"]], "a CLI that is not set up is skipped");

    const synced = await syncDelegatorSkill(options);
    assert.deepEqual(synced.updated, ["claude", "codex"]);
    assert.equal(await readFile(join(targets[0].path, "SKILL.md"), "utf8"), "new instructions\n");
    assert.equal(await readFile(join(targets[2].path, "SKILL.md"), "utf8"), "my own instructions\n", "an edit is kept");
    assert.deepEqual(Object.keys(JSON.parse(await readFile(recordPath, "utf8")).skills).sort(), ["claude", "codex"]);

    // The user chose to replace their edit, and to add it where it was missing.
    await mkdir(targets[3].home, { recursive: true });
    const forced = await syncDelegatorSkill({ ...options, force: ["grok"], install: ["auggie"] });
    assert.deepEqual(forced.updated.sort(), ["auggie", "grok"]);
    assert.ok(forced.targets.every((item) => item.state === "current"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("the shipped skill stays compact and model-agnostic", async () => {
  const text = await readFile(new URL("../skills/agent-delegator/SKILL.md", import.meta.url), "utf8");
  assert.ok(text.split("\n").length <= 60, "SKILL.md is loaded into every Main; keep it short");
  assert.doesNotMatch(text, /grok-4|gpt-5|opus|sonnet/i, "choosing a model is not this skill's job");
  assert.match(text, /waitMs: 0/, "turns start in the background");
});
