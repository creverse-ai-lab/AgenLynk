import { homedir } from "node:os";
import { join } from "node:path";

export function defaultInstallStatePath() {
  return process.env.ACP_GATEWAY_INSTALL_STATE || join(homedir(), ".acp-gateway", "install.json");
}
