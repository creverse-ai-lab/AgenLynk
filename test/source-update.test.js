import assert from "node:assert/strict";
import test from "node:test";
import { updateSourceCheckout } from "../src/source-update.js";

test("source update pulls, checks upstream, and validates before applying the installer", async () => {
  const calls = [];
  const responses = [
    { code: 0, stdout: "true\n", stderr: "" },
    { code: 0, stdout: "", stderr: "" },
    { code: 0, stdout: "Already up to date.\n", stderr: "" },
    { code: 0, stdout: "installed\n", stderr: "" },
    { code: 2, stdout: "upstream changes detected\n", stderr: "" },
    { code: 0, stdout: "84 tests passed\n", stderr: "" }
  ];
  const result = await updateSourceCheckout("/repo", {
    run: async (command, args, cwd) => {
      calls.push({ command, args, cwd });
      return responses.shift();
    }
  });
  assert.deepEqual(calls.map(({ command, args }) => [command, ...args]), [
    ["git", "rev-parse", "--is-inside-work-tree"],
    ["git", "status", "--porcelain"],
    ["git", "pull", "--ff-only"],
    ["npm", "ci"],
    ["npm", "run", "monitor:check"],
    ["npm", "run", "ci"]
  ]);
  assert.equal(result.pull, "Already up to date.");
  assert.equal(result.upstream.changesDetected, true);
  assert.equal(result.upstream.maintainerCommand, "npm run update:upstream");
  assert.equal(result.validation, "84 tests passed");
});

test("source update reports an unavailable upstream check but still requires local validation", async () => {
  const responses = [
    { code: 0, stdout: "true\n", stderr: "" },
    { code: 0, stdout: "", stderr: "" },
    { code: 0, stdout: "Already up to date.\n", stderr: "" },
    { code: 0, stdout: "installed\n", stderr: "" },
    { code: 1, stdout: "", stderr: "rate limited" },
    { code: 0, stdout: "validated\n", stderr: "" }
  ];
  const result = await updateSourceCheckout("/repo", { run: async () => responses.shift() });
  assert.equal(result.upstream.checked, false);
  assert.match(result.upstream.warning, /rate limited/);
  assert.equal(result.validation, "validated");
});

test("source update refuses to overwrite local changes", async () => {
  const responses = [
    { code: 0, stdout: "true\n", stderr: "" },
    { code: 0, stdout: " M src/file.js\n", stderr: "" }
  ];
  await assert.rejects(
    updateSourceCheckout("/repo", { run: async () => responses.shift() }),
    /commit or stash/
  );
  assert.equal(responses.length, 0);
});
