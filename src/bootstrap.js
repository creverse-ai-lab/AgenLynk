#!/usr/bin/env node

import { spawn } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { updateSourceCheckout } from "./source-update.js";
import { GATEWAY_VERSION } from "./version.js";

try {
  const argv = process.argv.slice(2);
  const isUpdate = argv.includes("--update");
  const isExplicitDryRun = argv.includes("--dry-run");
  const applyStage = process.env.ACP_GATEWAY_BOOTSTRAP_STAGE === "apply";

  if (argv.includes("--version") || argv.includes("-V")) {
    process.stdout.write(`acp-gateway-bootstrap ${GATEWAY_VERSION}\n`);
  } else if (isUpdate && !isExplicitDryRun && !applyStage) {
    const bootstrapPath = fileURLToPath(import.meta.url);
    const root = dirname(dirname(bootstrapPath));
    const source = await updateSourceCheckout(root);
    process.stderr.write(`${JSON.stringify({ phase: "source-update", ...source }, null, 2)}\n`);
    const code = await runUpdatedBootstrap(bootstrapPath, argv);
    process.exitCode = code;
  } else {
    const { installerHelp, parseInstallerArgs, runInstaller } = await import("./installer.js");
    const options = parseInstallerArgs(argv);
    await chooseFrontDoor(options);
    if (options.help) {
      process.stdout.write(`${installerHelp()}\n`);
    } else {
      if (options.update && !options.dryRun) {
        const plan = await runInstaller({ ...options, dryRun: true, healthCheck: false });
        process.stderr.write(`${JSON.stringify({ phase: "dry-run", ...plan }, null, 2)}\n`);
      }
      process.stdout.write(`${JSON.stringify(await runInstaller(options), null, 2)}\n`);
    }
  }
} catch (error) {
  process.stderr.write(`acp-gateway-bootstrap: ${error?.message ?? String(error)}\n`);
  process.exitCode = 1;
}

async function chooseFrontDoor(options) {
  if (options.help || !options.installAll || options.frontDoor || options.targets.length) return;
  if (!process.stdin.isTTY || !process.stderr.isTTY) {
    options.frontDoor = "codex";
    return;
  }
  const { createInterface } = await import("node:readline/promises");
  const terminal = createInterface({ input: process.stdin, output: process.stderr });
  const choices = { "": "codex", "1": "codex", codex: "codex", "2": "claude", claude: "claude", "3": "grok", grok: "grok" };
  try {
    process.stderr.write("Choose the ACP Gateway front door:\n  1) Codex (default)\n  2) Claude\n  3) Grok\n");
    while (!options.frontDoor) {
      const answer = (await terminal.question("Front door [1]: ")).trim().toLowerCase();
      options.frontDoor = choices[answer] ?? null;
      if (!options.frontDoor) process.stderr.write("Enter 1, 2, 3, codex, claude, or grok.\n");
    }
  } finally {
    terminal.close();
  }
}

function runUpdatedBootstrap(bootstrapPath, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [bootstrapPath, ...args], {
      stdio: "inherit",
      env: { ...process.env, ACP_GATEWAY_BOOTSTRAP_STAGE: "apply" }
    });
    child.once("error", reject);
    child.once("close", (code) => resolve(code ?? 1));
  });
}
