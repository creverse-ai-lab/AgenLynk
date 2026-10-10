import { createHash } from "node:crypto";
import { chmod, mkdir, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { collectGatewayInventory, gatewaySourceDigest } from "../../src/runtime-manifest.js";

export const OFFICIAL_CLAUDE_HELPER_PATH = "node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude";
export const GATEWAY_PACKAGE_PATH = "node_modules/acp-gateway-daemon";

function sourceCommit(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 40);
}

function sha256Text(value) {
  return createHash("sha256").update(value).digest("hex");
}

function fileRecord(path, contents, mode = "0644") {
  return { path, type: "file", mode, bytes: Buffer.byteLength(contents), sha256: sha256Text(contents) };
}

function directoryRecord(path) {
  return { path, type: "directory", mode: "0755", bytes: 0 };
}

const clientJs = "export const GATEWAY_API_VERSION = 1; export class GatewayRpcClient {} export class GatewayError extends Error {} export const ERROR_CODES = {};\n";

async function writeAppRuntimeAndNode(root, nodeVersion) {
  await mkdir(join(root, "app-runtime"), { recursive: true });
  await mkdir(join(root, "node/bin"), { recursive: true });
  for (const name of [
    "runtime-installer-cli.js",
    "runtime-installer.js",
    "runtime-updater-cli.js",
    "runtime-updater.js"
  ]) await writeFile(join(root, "app-runtime", name), "export default {};\n");

  for (const [name, output] of [["node", `v${nodeVersion}`], ["npm", "10.9.0"], ["npx", "10.9.0"]]) {
    const path = join(root, "node/bin", name);
    await writeFile(path, `#!/bin/sh\necho "${output}"\n`);
    await chmod(path, 0o755);
  }
}

/**
 * A runtime seed in the npm package layout (manifest format 5) by default, or
 * with `layout: "tarball"` the Gateway <= 1.6 layout that mounted the GitHub
 * runtime tarball at gateway/ (format 4).
 */
export async function writeRuntimeSeed(root, options = {}) {
  return options.layout === "tarball" ? writeTarballRuntimeSeed(root, options) : writeNpmRuntimeSeed(root, options);
}

async function writeNpmRuntimeSeed(
  root,
  {
    gatewayVersion = "1.8.0",
    gatewayBuildId = "fixture-gateway",
    gatewayApiVersion = 1,
    nodeVersion = "22.14.0",
    marker = "fixture",
    provenanceVerified = true
  } = {}
) {
  const commit = sourceCommit(gatewayBuildId);
  const integrity = `sha512-${createHash("sha512").update(`${gatewayVersion}:${gatewayBuildId}`).digest("base64")}`;
  const registry = "https://registry.npmjs.org/";
  const tarball = `${registry}acp-gateway-daemon/-/acp-gateway-daemon-${gatewayVersion}.tgz`;
  const packageRoot = join(root, GATEWAY_PACKAGE_PATH);
  await mkdir(join(packageRoot, "gateway-client"), { recursive: true });
  await mkdir(join(packageRoot, "src"), { recursive: true });

  const lock = {
    schemaVersion: 2,
    version: gatewayVersion,
    apiMajor: gatewayApiVersion,
    tag: `v${gatewayVersion}`,
    sourceCommit: commit,
    package: {
      name: "acp-gateway-daemon",
      registry,
      tarball,
      integrity,
      installPath: GATEWAY_PACKAGE_PATH,
      clientSpecifier: "acp-gateway-daemon/client"
    },
    provenance: {
      predicateType: "https://slsa.dev/provenance/v1",
      repository: "https://github.com/creverse-ai-lab/agent_gateway",
      workflow: ".github/workflows/publish-npm.yml",
      ref: `refs/tags/v${gatewayVersion}`
    },
    node: {
      provider: "app",
      version: nodeVersion,
      distribution: `https://nodejs.org/download/release/v${nodeVersion}/node-v${nodeVersion}-darwin-arm64.tar.xz`,
      sha256: "5eff7a9011895aae3f29d06f167b84a62b028a591370c7cafb59103559fd26e1",
      installPath: "node"
    },
    publicEntrypoint: "gateway-client/index.js",
    platform: "darwin",
    arch: "arm64"
  };
  await writeFile(join(root, "gateway.lock.json"), `${JSON.stringify(lock)}\n`);
  await writeFile(join(packageRoot, "package.json"), JSON.stringify({
    name: "acp-gateway-daemon",
    version: gatewayVersion,
    type: "module",
    exports: { ".": "./gateway-client/index.js", "./client": "./gateway-client/index.js" }
  }));
  await writeFile(join(packageRoot, "src/index.js"), `export const marker = ${JSON.stringify(marker)};\n`);
  for (const name of ["guide.js", "bootstrap.js", "gateway-daemon.js"]) {
    await writeFile(join(packageRoot, "src", name), "export default {};\n");
  }
  await writeFile(join(packageRoot, "gateway-client/index.js"), clientJs);
  await symlink(GATEWAY_PACKAGE_PATH, join(root, "gateway"));

  const record = {
    schemaVersion: 1,
    name: "acp-gateway-daemon",
    version: gatewayVersion,
    tarball,
    integrity,
    sourceCommit: commit,
    provenance: provenanceVerified
      ? { verified: true, predicateType: lock.provenance.predicateType, repository: lock.provenance.repository, workflow: lock.provenance.workflow, ref: lock.provenance.ref, sourceCommit: commit }
      : { verified: false, reason: "skipped" },
    files: await collectGatewayInventory(packageRoot)
  };
  await writeFile(join(root, "gateway-package.json"), `${JSON.stringify(record)}\n`);
  await writeAppRuntimeAndNode(root, nodeVersion);
  return { commit, gatewayBuildId: await gatewaySourceDigest(packageRoot), integrity };
}

async function writeTarballRuntimeSeed(
  root,
  {
    gatewayVersion = "1.6.0",
    gatewayBuildId = "fixture-gateway",
    gatewayApiVersion = 1,
    nodeVersion = "22.14.0",
    marker = "fixture",
    includeOfficialHelper = false,
    officialHelperContents = "official-helper\n"
  } = {}
) {
  const commit = sourceCommit(gatewayBuildId);
  const assetSha256 = "c03ad69362e4f75b115f345aeafccc03fc9895a3ebb539e6fe8342bea16bfc8c";
  await mkdir(join(root, "gateway/gateway-client"), { recursive: true });
  await mkdir(join(root, "gateway/src"), { recursive: true });

  const lock = {
    schemaVersion: 1,
    version: gatewayVersion,
    apiMajor: gatewayApiVersion,
    tag: `v${gatewayVersion}`,
    sourceCommit: commit,
    asset: {
      name: "acp-gateway-runtime-darwin-arm64.tar.gz",
      url: `https://example.invalid/${gatewayVersion}/acp-gateway-runtime-darwin-arm64.tar.gz`,
      sha256: assetSha256
    },
    runtimeRoot: "acp-gateway-runtime",
    publicEntrypoint: "gateway-client/index.js",
    platform: "darwin",
    arch: "arm64"
  };
  const packageJson = JSON.stringify({ name: "acp-gateway", version: gatewayVersion, type: "module" });
  const packageLock = "{}\n";
  const indexJs = `export const marker = ${JSON.stringify(marker)};\n`;
  const bootstrapJs = "export default {};\n";

  await writeFile(join(root, "gateway.lock.json"), `${JSON.stringify(lock)}\n`);
  await writeFile(join(root, "gateway/package.json"), packageJson);
  await writeFile(join(root, "gateway/package-lock.json"), packageLock);
  await writeFile(join(root, "gateway/src/index.js"), indexJs);
  await writeFile(join(root, "gateway/src/bootstrap.js"), bootstrapJs);
  await writeFile(join(root, "gateway/gateway-client/index.js"), clientJs);

  const files = [
    fileRecord("package.json", packageJson),
    fileRecord("package-lock.json", packageLock),
    directoryRecord("src/"),
    fileRecord("src/index.js", indexJs),
    fileRecord("src/bootstrap.js", bootstrapJs),
    directoryRecord("gateway-client/"),
    fileRecord("gateway-client/index.js", clientJs)
  ];

  if (includeOfficialHelper) {
    await mkdir(join(root, "gateway/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64"), { recursive: true });
    await writeFile(join(root, "gateway", OFFICIAL_CLAUDE_HELPER_PATH), officialHelperContents);
    files.push(
      directoryRecord("node_modules/"),
      directoryRecord("node_modules/@anthropic-ai/"),
      directoryRecord("node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/"),
      fileRecord(OFFICIAL_CLAUDE_HELPER_PATH, officialHelperContents, "0755")
    );
  }

  const upstream = {
    schemaVersion: 1,
    package: "acp-gateway",
    version: gatewayVersion,
    apiMajor: gatewayApiVersion,
    platform: "darwin",
    arch: "arm64",
    runtimeRoot: "acp-gateway-runtime",
    publicEntrypoint: "./gateway-client/index.js",
    artifact: lock.asset.name,
    source: { tag: lock.tag, commit },
    files
  };
  await writeFile(join(root, "gateway/runtime-manifest.json"), `${JSON.stringify(upstream)}\n`);
  await writeAppRuntimeAndNode(root, nodeVersion);
  return { commit, officialHelperSha256: includeOfficialHelper ? sha256Text(officialHelperContents) : null };
}
