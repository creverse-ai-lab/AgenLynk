import assert from "node:assert/strict";
import test from "node:test";
import { readGatewayLock } from "../scripts/fetch-gateway-runtime.js";

test("gateway.lock.json pins the acp-gateway-daemon 1.8.0 npm package and the app-provided Node", async () => {
  const lock = await readGatewayLock();
  assert.equal(lock.schemaVersion, 2);
  assert.equal(lock.version, "1.8.0");
  assert.equal(lock.apiMajor, 1);
  assert.equal(lock.tag, "v1.8.0");
  assert.equal(lock.sourceCommit, "0757151df8084f0b5c863902f08011583822207e");
  assert.equal(lock.package.name, "acp-gateway-daemon");
  assert.equal(lock.package.tarball, "https://registry.npmjs.org/acp-gateway-daemon/-/acp-gateway-daemon-1.8.0.tgz");
  assert.equal(lock.package.integrity, "sha512-ib4pxg+EvllRZVvh2mAlgROdicYAKpx/uds49ZQsoJZXy85mGLU1Apln8fHQC4jM4PHdTk/gbnc9TjGqm2seEg==");
  assert.equal(lock.package.installPath, "node_modules/acp-gateway-daemon");
  assert.equal(lock.package.clientSpecifier, "acp-gateway-daemon/client");
  assert.equal(lock.provenance.repository, "https://github.com/creverse-ai-lab/agent_gateway");
  assert.equal(lock.provenance.workflow, ".github/workflows/publish-npm.yml");
  assert.equal(lock.provenance.ref, "refs/tags/v1.8.0");
  assert.equal(lock.node.provider, "app");
  assert.equal(lock.node.version, "22.23.2");
  assert.equal(lock.node.sha256, "5eff7a9011895aae3f29d06f167b84a62b028a591370c7cafb59103559fd26e1");
  assert.equal(lock.publicEntrypoint, "gateway-client/index.js");
});
