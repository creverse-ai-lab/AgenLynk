// Temporary AgenLynk 0.4.0 seam over the bundled Gateway 1.3.2 fork.
//
// Sidecar code must import Gateway implementation details only through this
// file. Phase 4 replaces these exports with the public 1.4.0 client/runtime
// contract and removes this adapter.

export { pathIsMissing } from "../../../src/fs-paths.js";
export { GatewayRpcClient } from "../../../src/socket-rpc.js";
export { gatewaySocketPath } from "../../../src/config.js";
export {
  GATEWAY_BUILD_ID,
  GATEWAY_RUNTIME_ROOT
} from "../../../src/version.js";
export {
  defaultGatewaySettings,
  gatewaySettingsSnapshot,
  resolveGatewaySettings,
  updateGatewaySettings
} from "../../../src/gateway-settings.js";
export {
  installOfficialAgent,
  officialAgentCatalog,
  setOfficialAgentEnabled
} from "../../../src/agent-catalog.js";
export { defaultInstallStatePath } from "../../../src/installer.js";

// Characterization/integration-test access stays on the same temporary seam.
export { GatewayService } from "../../../src/gateway-service.js";
export { createSocketSender } from "../../../src/socket-flow.js";
export const LEGACY_GATEWAY_DAEMON_URL = new URL("../../../src/gateway-daemon.js", import.meta.url);
