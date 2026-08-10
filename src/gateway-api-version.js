// Versions the Monitor/Control handshake shape returned by `setup`
// (gatewayApiVersion, runtimeRoot, runtimeSource, capabilities, ...) —
// independent of GATEWAY_VERSION (the release number) and ACP_PROTOCOL_VERSION
// (the upstream agent protocol). Bump only when a field is removed, renamed,
// or changes meaning; additive fields do not require a bump. A client should
// ignore unknown capabilities/fields and only refuse an unsupported major.
export const GATEWAY_API_VERSION = 1;

/**
 * Thrown when a Gateway's reported `gatewayApiVersion` isn't the exact major
 * this installer/client speaks. Structured (stable `code` + version fields)
 * rather than a bare message, so callers can act on it instead of sniffing
 * error text.
 */
export class UnsupportedGatewayApiVersionError extends Error {
  constructor({ reportedGatewayApiVersion, supportedGatewayApiVersion = GATEWAY_API_VERSION, requiredGatewayApiVersion } = {}) {
    const reported = reportedGatewayApiVersion === null || reportedGatewayApiVersion === undefined
      ? "unknown"
      : JSON.stringify(reportedGatewayApiVersion);
    super(
      `Gateway API version ${reported} is not supported by this installer `
      + `(requires exactly ${supportedGatewayApiVersion}); update Lynk/ACP Gateway to a matching release`
    );
    this.name = "UnsupportedGatewayApiVersionError";
    this.code = "UNSUPPORTED_GATEWAY_API_VERSION";
    this.reportedGatewayApiVersion = reportedGatewayApiVersion ?? null;
    this.supportedGatewayApiVersion = supportedGatewayApiVersion;
    // Only meaningful when the reported major is a well-formed, higher
    // integer: that's the one case where "required" has an unambiguous
    // answer (the client would need to understand at least that major). A
    // lower or malformed/non-integer report doesn't have a comparable
    // single "required" value, so the field is omitted rather than guessed.
    if (requiredGatewayApiVersion !== undefined) this.requiredGatewayApiVersion = requiredGatewayApiVersion;
  }
}
