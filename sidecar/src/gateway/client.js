// The only Gateway code entrypoint used by the AgenLynk sidecar.
// Swift supplies the verified active runtime's Phase 3 public client path.
import { pathToFileURL } from "node:url";

const entrypoint = process.env.ACP_GATEWAY_CLIENT_ENTRYPOINT;
if (!entrypoint) {
  throw new Error("ACP_GATEWAY_CLIENT_ENTRYPOINT must point to the active Gateway public client");
}
if (!entrypoint.endsWith("/gateway-client/index.js")) {
  throw new Error("ACP_GATEWAY_CLIENT_ENTRYPOINT is not the Gateway public client entrypoint");
}

const client = await import(pathToFileURL(entrypoint).href);
if (client.GATEWAY_API_VERSION !== 1 || typeof client.GatewayRpcClient !== "function") {
  throw new Error("Gateway public client is incompatible with AgenLynk 0.4.0");
}

export const {
  ERROR_CODES,
  GATEWAY_API_VERSION,
  GatewayError,
  GatewayRpcClient
} = client;
