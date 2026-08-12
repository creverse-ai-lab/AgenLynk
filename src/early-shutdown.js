// Registers the SIGTERM/SIGINT handler at the earliest possible moment.
//
// index.js imports this FIRST, before the heavy MCP SDK. ES modules evaluate
// their imports in order, so this module's body runs — installing the signal
// handler — before those slow imports load. Without it, a SIGTERM arriving
// during startup (a cold Node in CI can still be loading modules 200ms in)
// killed the process by signal instead of exiting cleanly, so a caller saw a
// null exit code where it expected 0.
//
// The real cleanup (closing the RPC socket and MCP server) is wired in later
// via onShutdown once those exist; until then the handler just exits 0, which
// is the correct outcome for "terminated before it finished starting".

let cleanup = null;

export function onShutdown(fn) {
  cleanup = fn;
}

let shuttingDown = false;
function handle() {
  if (shuttingDown) return;
  shuttingDown = true;
  if (cleanup) cleanup();
  else process.exit(0);
}

process.once("SIGTERM", handle);
process.once("SIGINT", handle);
