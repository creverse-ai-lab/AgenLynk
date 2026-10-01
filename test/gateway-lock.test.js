import assert from "node:assert/strict";
import test from "node:test";
import { readGatewayLock } from "../scripts/fetch-gateway-runtime.js";

test("gateway.lock.json pins the acp-gateway-daemon 1.7.2 npm package and the app-provided Node", async () => {
  const lock = await readGatewayLock();
  assert.equal(lock.schemaVersion, 2);
  assert.equal(lock.version, "1.7.2");
  assert.equal(lock.apiMajor, 1);
  assert.equal(lock.tag, "v1.7.2");
  assert.equal(lock.sourceCommit, "009a5174657d09e471101a5fdc217aa6a2a8698a");
  assert.equal(lock.package.name, "acp-gateway-daemon");
  assert.equal(lock.package.tarball, "https://registry.npmjs.org/acp-gateway-daemon/-/acp-gateway-daemon-1.7.2.tgz");
  assert.equal(lock.package.integrity, "sha512-8hMJXQUjXtORW18cPrIFfxRIy7zQlOdiLhjgWb4FChT62WYBXIhOugFLqedmOvewkc7T9jYeTQ18InLATpC37A==");
  assert.equal(lock.package.installPath, "node_modules/acp-gateway-daemon");
  assert.equal(lock.package.clientSpecifier, "acp-gateway-daemon/client");
  assert.equal(lock.provenance.repository, "https://github.com/creverse-ai-lab/agent_gateway");
  assert.equal(lock.provenance.workflow, ".github/workflows/publish-npm.yml");
  assert.equal(lock.provenance.ref, "refs/tags/v1.7.2");
  assert.equal(lock.node.provider, "app");
  assert.equal(lock.node.version, "22.23.2");
  assert.equal(lock.node.sha256, "5eff7a9011895aae3f29d06f167b84a62b028a591370c7cafb59103559fd26e1");
  assert.equal(lock.publicEntrypoint, "gateway-client/index.js");
});
