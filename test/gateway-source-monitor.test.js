import assert from "node:assert/strict";
import test from "node:test";
import { checkGatewaySource } from "../src/gateway-source-monitor.js";
import { GATEWAY_VERSION } from "../src/version.js";

test("Gateway source monitor reports a newer version on remote main", async () => {
  let requestedUrl;
  const result = await checkGatewaySource({
    run: async () => "https://github.com/nesto-ai/agent_gateway.git\n",
    fetchImpl: async (url) => {
      requestedUrl = url;
      return { ok: true, text: async () => JSON.stringify({ version: "1.3.0" }) };
    },
    now: () => Date.parse("2026-08-02T00:00:00.000Z")
  });
  assert.equal(requestedUrl, "https://raw.githubusercontent.com/nesto-ai/agent_gateway/main/package.json");
  assert.equal(result.currentVersion, GATEWAY_VERSION);
  assert.equal(result.mainVersion, "1.3.0");
  assert.equal(result.updateAvailable, true);
});

test("Gateway source monitor does not treat an older main as an update", async () => {
  const result = await checkGatewaySource({
    run: async () => "git@github.com:nesto-ai/agent_gateway.git\n",
    fetchImpl: async () => ({ ok: true, text: async () => JSON.stringify({ version: "1.0.0" }) })
  });
  assert.equal(result.updateAvailable, false);
});
