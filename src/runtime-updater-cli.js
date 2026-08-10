#!/usr/bin/env node
// Thin CLI wrapper around runtime-updater.js. Not registered as an npm `bin`
// entry (same convention as runtime-installer-cli.js): callers invoke it by
// absolute path with the currently-active runtime's own bundled Node.
// Prints exactly one JSON envelope to stdout for every outcome — success or
// expected failure alike — and sets a nonzero exit code only on failure.
// There is no way to pass a shell command as a health/smoke check here: the
// library's builtin deterministic check is always used.
import {
  activateRuntimeCandidate,
  defaultRuntimeRoot,
  inspectRuntime,
  pruneRuntimeVersions,
  rollbackRuntime,
  stageRuntimeCandidate,
  validateRuntimeCandidate
} from "./runtime-updater.js";

function parseFlags(argv) {
  const flags = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    if (eq !== -1) {
      flags[arg.slice(2, eq)] = arg.slice(eq + 1);
      continue;
    }
    const next = argv[index + 1];
    if (next !== undefined && !next.startsWith("--")) {
      flags[arg.slice(2)] = next;
      index += 1;
    } else {
      flags[arg.slice(2)] = "true";
    }
  }
  return flags;
}

function parseJsonFlag(raw, label) {
  if (raw === undefined) return undefined;
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`--${label} must be valid JSON: ${error.message}`);
  }
}

const OPERATIONS = {
  inspect: (flags) => inspectRuntime({
    runtimeRoot: flags["runtime-root"] ?? defaultRuntimeRoot(),
    deep: flags.deep === "true"
  }),
  stage: (flags) => stageRuntimeCandidate({
    runtimeRoot: flags["runtime-root"] ?? defaultRuntimeRoot(),
    seedRoot: flags.seed
  }),
  validate: (flags) => validateRuntimeCandidate({
    runtimeRoot: flags["runtime-root"] ?? defaultRuntimeRoot(),
    versionId: flags.version
  }),
  activate: (flags) => activateRuntimeCandidate({
    runtimeRoot: flags["runtime-root"] ?? defaultRuntimeRoot(),
    versionId: flags.version,
    blockers: parseJsonFlag(flags.blockers, "blockers")
  }),
  rollback: (flags) => rollbackRuntime({
    runtimeRoot: flags["runtime-root"] ?? defaultRuntimeRoot(),
    blockers: parseJsonFlag(flags.blockers, "blockers")
  }),
  prune: (flags) => pruneRuntimeVersions({
    runtimeRoot: flags["runtime-root"] ?? defaultRuntimeRoot(),
    keep: parseJsonFlag(flags.keep, "keep") ?? []
  })
};

const [op, ...rest] = process.argv.slice(2);
let result;

if (!op || !OPERATIONS[op]) {
  result = {
    ok: false,
    op: op ?? null,
    error: { code: "INVALID_ARGS", message: `unknown or missing operation (expected one of: ${Object.keys(OPERATIONS).join(", ")})` }
  };
} else {
  try {
    result = await OPERATIONS[op](parseFlags(rest));
  } catch (error) {
    // Only reachable for CLI-side arg parsing failures (e.g. malformed
    // --blockers/--keep JSON) — runtime-updater.js's own operations already
    // return a failure envelope instead of throwing.
    result = { ok: false, op, error: { code: error?.code ?? "INVALID_ARGS", message: error?.message ?? String(error) } };
  }
}

process.stdout.write(`${JSON.stringify(result)}\n`);
process.exitCode = result.ok ? 0 : 1;
