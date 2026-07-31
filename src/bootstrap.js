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
