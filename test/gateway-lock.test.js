import assert from "node:assert/strict";
import test from "node:test";
import { readGatewayLock } from "../scripts/fetch-gateway-runtime.js";

test("gateway.lock.json pins the immutable Gateway 1.5.2 darwin-arm64 artifact", async () => {
  const lock = await readGatewayLock();
  assert.equal(lock.version, "1.5.2");
  assert.equal(lock.apiMajor, 1);
  assert.equal(lock.tag, "v1.5.2");
  assert.equal(lock.sourceCommit, "336bad26353b79887f87687b3cb8235b26e9e5e1");
  assert.equal(lock.asset.name, "acp-gateway-runtime-darwin-arm64.tar.gz");
  assert.equal(lock.asset.sha256, "d54812421917b63e833d126c1f033b8758c1bd64b07529f1e1792183f1aee27d");
  assert.equal(lock.publicEntrypoint, "gateway-client/index.js");
});
