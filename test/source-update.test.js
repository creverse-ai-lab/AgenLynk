import assert from "node:assert/strict";
import test from "node:test";
import { updateSourceCheckout } from "../src/source-update.js";

test("source update pulls fast-forward only before installing dependencies", async () => {
  const calls = [];
  const responses = [
    { code: 0, stdout: "true\n", stderr: "" },
    { code: 0, stdout: "", stderr: "" },
    { code: 0, stdout: "Already up to date.\n", stderr: "" },
    { code: 0, stdout: "installed\n", stderr: "" }
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
    ["npm", "ci"]
  ]);
  assert.equal(result.pull, "Already up to date.");
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
