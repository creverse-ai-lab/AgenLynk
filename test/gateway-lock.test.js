import assert from "node:assert/strict";
import test from "node:test";
import { readGatewayLock } from "../scripts/fetch-gateway-runtime.js";

test("gateway.lock.json pins the immutable Gateway 1.4.0 darwin-arm64 artifact", async () => {
  const lock = await readGatewayLock();
  assert.equal(lock.version, "1.4.0");
  assert.equal(lock.apiMajor, 1);
  assert.equal(lock.tag, "v1.4.0");
  assert.equal(lock.sourceCommit, "a1fdb353777337ca6ec481f8563d77efaea55e95");
  assert.equal(lock.asset.name, "acp-gateway-runtime-darwin-arm64.tar.gz");
  assert.equal(lock.asset.sha256, "c03ad69362e4f75b115f345aeafccc03fc9895a3ebb539e6fe8342bea16bfc8c");
  assert.equal(lock.publicEntrypoint, "gateway-client/index.js");
});
