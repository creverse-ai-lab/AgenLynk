import { ERROR_CODES } from "./client.js";

const REQUIRED_RESPONSE_PROFILES = ["current", "compact", "diagnostic"];
export const SUPPORTED_STATE_SCHEMA_VERSION = 5;

export function decodeGatewaySetup(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return incompatibleSetup(value, "Gateway setup response is not an object");
  }
  const apiCompatible = value.gatewayApiVersion === 1;
  const profiles = Array.isArray(value.responseProfiles)
    ? value.responseProfiles.filter((item) => typeof item === "string")
    : [];
  const hasExactSchema = value.stateSchemaVersion === SUPPORTED_STATE_SCHEMA_VERSION;
  const hasProfiles = REQUIRED_RESPONSE_PROFILES.every((profile) => profiles.includes(profile));
  const is140 = apiCompatible && hasExactSchema && hasProfiles;
  const status = is140 ? "supported" : apiCompatible ? "legacy_unsupported" : "incompatible";
  const reason = is140
    ? null
    : apiCompatible
      ? hasExactSchema
        ? "Gateway 1.3.x lacks the declared 1.4.0 state/profile/gap contract"
        : `Gateway state schema ${value.stateSchemaVersion ?? "unknown"} is not the pinned 1.4.0 schema ${SUPPORTED_STATE_SCHEMA_VERSION}`
      : `Gateway API major ${value.gatewayApiVersion ?? "unknown"} is unsupported`;
  return {
    ...value,
    compatibility: {
      status,
      reason,
      features: {
        subscriptionGaps: is140,
        responseProfiles: is140,
        stateSchema: is140,
        sessionConfig: is140,
        gatewayConfigRpc: false,
        retentionPreviewRpc: false
      }
    }
  };
}

function incompatibleSetup(value, reason) {
  return {
    ...(value && typeof value === "object" && !Array.isArray(value) ? value : {}),
    compatibility: {
      status: "incompatible",
      reason,
      features: {
        subscriptionGaps: false,
        responseProfiles: false,
        stateSchema: false,
        sessionConfig: false,
        gatewayConfigRpc: false,
        retentionPreviewRpc: false
      }
    }
  };
}

export function gatewayFeatureAvailable(setup, feature) {
  return setup?.compatibility?.status === "supported"
    && setup.compatibility.features?.[feature] === true;
}

export function isGatewayError(error, code) {
  const stableCode = ERROR_CODES?.[code] ?? code;
  return typeof stableCode === "string" && error?.code === stableCode;
}

export function unavailableFeatureError(feature) {
  const error = new Error(`${feature} is unavailable with the active Gateway contract`);
  error.statusCode = 501;
  error.code = "monitor_feature_unavailable";
  return error;
}
