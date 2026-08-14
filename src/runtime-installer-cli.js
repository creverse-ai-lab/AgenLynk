#!/usr/bin/env node
// Thin CLI wrapper around runtime-installer.js, spawned by Swift's
// RuntimeProvisioner using the *bundled* seed Node (the only Node available
// before a runtime is installed). Prints a single JSON result line to stdout
// on success; everything else goes to stderr with a non-zero exit code.
import { ensureRuntimeInstalled } from "./runtime-installer.js";

function parseArgs(argv) {
  let seedRoot = null;
  let forceRepair = false;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--seed") {
      seedRoot = argv[++index];
    } else if (argv[index].startsWith("--seed=")) {
      seedRoot = argv[index].slice("--seed=".length);
    } else if (argv[index] === "--force-repair") {
      forceRepair = true;
    }
  }
  if (!seedRoot) throw new Error("--seed <runtime seed directory> is required");
  return { seedRoot, forceRepair };
}

try {
  const { seedRoot, forceRepair } = parseArgs(process.argv.slice(2));
  // Normal startup stays fail-closed. This explicit flag is only sent after
  // the user confirms the destructive recovery action in the native UI.
  const result = await ensureRuntimeInstalled({
    seedRoot,
    ...(forceRepair ? { blockers: [] } : {})
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  process.stderr.write(`runtime-installer-cli: ${error?.message ?? String(error)}\n`);
  process.exitCode = 1;
}
