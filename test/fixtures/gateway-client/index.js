export const GATEWAY_API_VERSION = 1;
export const ERROR_CODES = Object.freeze({});
export class GatewayError extends Error {}
export class GatewayRpcClient {
  constructor() {
    throw new Error("test public-client stub cannot open Gateway connections");
  }
}
