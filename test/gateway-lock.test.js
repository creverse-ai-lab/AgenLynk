import assert from "node:assert/strict";
import test from "node:test";
import { readGatewayLock } from "../scripts/fetch-gateway-runtime.js";

test("gateway.lock.json pins the acp-gateway-daemon 1.9.0 npm package and the app-provided Node", async () => {
  const lock = await readGatewayLock();
  assert.equal(lock.schemaVersion, 2);
  assert.equal(lock.version, "1.9.0");
  assert.equal(lock.apiMajor, 1);
  assert.equal(lock.tag, "v1.9.0");
  assert.equal(lock.sourceCommit, "9669951151ae9650731e2c1d23e94104056f6e2d");
  assert.equal(lock.package.name, "acp-gateway-daemon");
  assert.equal(lock.package.tarball, "https://registry.npmjs.org/acp-gateway-daemon/-/acp-gateway-daemon-1.9.0.tgz");
  assert.equal(lock.package.integrity, "sha512-5sV/ROLKX3RBKOyAY0HU68tI60vwim9FQnMo27/NS9qK+XEIUh9q6ugfSZDOPVyLtvQf7ub5jLXxEj+JIis+KQ==");
  assert.equal(lock.package.installPath, "node_modules/acp-gateway-daemon");
  assert.equal(lock.package.clientSpecifier, "acp-gateway-daemon/client");
  assert.equal(lock.provenance.repository, "https://github.com/creverse-ai-lab/agent_gateway");
  assert.equal(lock.provenance.workflow, ".github/workflows/publish-npm.yml");
  assert.equal(lock.provenance.ref, "refs/tags/v1.9.0");
  assert.equal(lock.node.provider, "app");
  assert.equal(lock.node.version, "22.23.2");
  assert.equal(lock.node.sha256, "5eff7a9011895aae3f29d06f167b84a62b028a591370c7cafb59103559fd26e1");
  assert.equal(lock.publicEntrypoint, "gateway-client/index.js");
});
