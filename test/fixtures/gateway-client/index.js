export const GATEWAY_API_VERSION = 1;
export const ERROR_CODES = Object.freeze({
  CONTROL_ACCESS_DENIED: "CONTROL_ACCESS_DENIED",
  UNKNOWN_METHOD: "UNKNOWN_METHOD"
});
export class GatewayError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
export class GatewayRpcClient {
  constructor() {
    throw new Error("test public-client stub cannot open Gateway connections");
  }
}
