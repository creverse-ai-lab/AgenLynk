import assert from "node:assert/strict";
import test from "node:test";
import { readGatewayLock } from "../scripts/fetch-gateway-runtime.js";

test("gateway.lock.json pins the immutable Gateway 1.6.0 darwin-arm64 artifact", async () => {
  const lock = await readGatewayLock();
  assert.equal(lock.version, "1.6.0");
  assert.equal(lock.apiMajor, 1);
  assert.equal(lock.tag, "v1.6.0");
  assert.equal(lock.sourceCommit, "949966f5e73ab3bab4b48a8f0773485a7cca278d");
  assert.equal(lock.asset.name, "acp-gateway-runtime-darwin-arm64.tar.gz");
  assert.equal(lock.asset.sha256, "0668b77c4211af704ad0efd26841b67eb4cf7295378a39d26e8158d4489ed108");
  assert.equal(lock.publicEntrypoint, "gateway-client/index.js");
});
