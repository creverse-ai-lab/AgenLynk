import { chmod, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

export async function writeRuntimeSeed(
  root,
  {
    gatewayVersion = "1.3.1",
    gatewayBuildId = "abc123",
    gatewayApiVersion = 1,
    nodeVersion = "22.14.0",
    sidecarVersion = "0.4.0",
    sidecarBuildId = "fixture-sidecar"
  } = {}
) {
  await mkdir(join(root, "src"), { recursive: true });
  await mkdir(join(root, "sidecar/src/server"), { recursive: true });
  await mkdir(join(root, "sidecar/src/gateway"), { recursive: true });
  await mkdir(join(root, "skills/agent-delegator"), { recursive: true });
  await mkdir(join(root, "node_modules/@agentclientprotocol/claude-agent-acp"), { recursive: true });
  await mkdir(join(root, "node_modules/@modelcontextprotocol/sdk"), { recursive: true });
  await mkdir(join(root, "node/bin"), { recursive: true });

  await writeFile(join(root, "package.json"), JSON.stringify({ type: "module" }));
  await writeFile(join(root, "package-lock.json"), "{}\n");
  await writeFile(join(root, "sidecar/package.json"), JSON.stringify({ type: "module", version: sidecarVersion }));
  await writeFile(
    join(root, "sidecar/src/version.js"),
    `export const SIDECAR_VERSION = ${JSON.stringify(sidecarVersion)};\nexport const SIDECAR_BUILD_ID = ${JSON.stringify(sidecarBuildId)};\n`
  );
  await writeFile(join(root, "sidecar/src/server/monitor.js"), "export default {};\n");
  await writeFile(join(root, "sidecar/src/gateway/legacy-adapter.js"), "export default {};\n");
  await writeFile(
    join(root, "src/version.js"),
    `export const GATEWAY_VERSION = ${JSON.stringify(gatewayVersion)};\nexport const GATEWAY_BUILD_ID = ${JSON.stringify(gatewayBuildId)};\n`
  );
  await writeFile(
    join(root, "src/gateway-api-version.js"),
    `export const GATEWAY_API_VERSION = ${JSON.stringify(gatewayApiVersion)};\n`
  );
  for (const name of ["index.js", "guide.js", "bootstrap.js", "installer.js"]) {
    await writeFile(join(root, "src", name), "export default {};\n");
  }
  await writeFile(join(root, "skills/agent-delegator/SKILL.md"), "# fixture skill\n");
  await writeFile(join(root, "node_modules/@agentclientprotocol/claude-agent-acp/package.json"), "{}\n");
  await writeFile(join(root, "node_modules/@modelcontextprotocol/sdk/package.json"), "{}\n");

  for (const [name, output] of [["node", `v${nodeVersion}`], ["npm", "10.9.0"], ["npx", "10.9.0"]]) {
    const path = join(root, "node/bin", name);
    await writeFile(path, `#!/bin/sh\necho "${output}"\n`);
    await chmod(path, 0o755);
  }
}
