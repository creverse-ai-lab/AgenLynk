#!/usr/bin/env node

import { installerHelp, parseInstallerArgs, runInstaller } from "./installer.js";

try {
  const options = parseInstallerArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${installerHelp()}\n`);
  } else {
    process.stdout.write(`${JSON.stringify(await runInstaller(options), null, 2)}\n`);
  }
} catch (error) {
  process.stderr.write(`acp-gateway-bootstrap: ${error?.message ?? String(error)}\n`);
  process.exitCode = 1;
}
