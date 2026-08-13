import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  decodeGatewaySetup,
  gatewayFeatureAvailable,
  isGatewayError,
  unavailableFeatureError,
  SUPPORTED_STATE_SCHEMA_VERSION
} from "../src/gateway/compatibility.js";

test("pinned Gateway 1.4.0 setup enables only declared consumer features", async () => {
  const fixture = JSON.parse(await readFile(new URL("./fixtures/gateway-setup-1.4.0.json", import.meta.url), "utf8"));
  const decoded = decodeGatewaySetup(fixture.setup);
  assert.equal(decoded.compatibility.status, fixture.expected.status);
  for (const [feature, expected] of Object.entries(fixture.expected).filter(([key]) => key !== "status")) {
    assert.equal(decoded.compatibility.features[feature], expected, feature);
  }
  assert.equal(gatewayFeatureAvailable(decoded, "subscriptionGaps"), true);
  assert.equal(fixture.setup.stateSchemaVersion, SUPPORTED_STATE_SCHEMA_VERSION);
  assert.equal(decoded.stateSchemaVersion, SUPPORTED_STATE_SCHEMA_VERSION);
});

test("1.4.0 profiles with the wrong state schema are legacy_unsupported", () => {
  const decoded = decodeGatewaySetup({
    ok: true,
    gatewayVersion: "1.4.0",
    gatewayApiVersion: 1,
    stateSchemaVersion: 1,
    responseProfiles: ["current", "compact", "diagnostic"]
  });
  assert.equal(decoded.compatibility.status, "legacy_unsupported");
  assert.equal(gatewayFeatureAvailable(decoded, "subscriptionGaps"), false);
});

test("legacy 1.3.2 setup is explicit legacy_unsupported, not guessed compatible", async () => {
  const golden = JSON.parse(await readFile(new URL("./fixtures/gateway-setup-1.3.2.json", import.meta.url), "utf8"));
  const decoded = decodeGatewaySetup(golden.stable);
  assert.equal(decoded.compatibility.status, "legacy_unsupported");
  assert.equal(gatewayFeatureAvailable(decoded, "sessionConfig"), false);
  assert.equal(gatewayFeatureAvailable(decoded, "subscriptionGaps"), false);
});

test("compatibility branches only on stable Gateway error codes", () => {
  assert.equal(isGatewayError({ code: "CONTROL_ACCESS_DENIED", message: "rewritten" }, "CONTROL_ACCESS_DENIED"), true);
  assert.equal(isGatewayError({ message: "Control access denied" }, "CONTROL_ACCESS_DENIED"), false);
  const unavailable = unavailableFeatureError("retention preview");
  assert.equal(unavailable.statusCode, 501);
  assert.equal(unavailable.code, "monitor_feature_unavailable");
});
