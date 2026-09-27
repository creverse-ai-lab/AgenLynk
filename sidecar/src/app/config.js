import { readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const uid = typeof process.getuid === "function" ? process.getuid() : "user";

export function gatewaySocketPath() {
  return process.env.ACP_GATEWAY_SOCKET || join(tmpdir(), `acp-gateway-${uid}.sock`);
}

export function controlIdentity({
  env = process.env,
  statePath = env.ACP_GATEWAY_INSTALL_STATE || join(homedir(), ".acp-gateway", "install.json")
} = {}) {
  let stored = null;
  if (!env.ACP_GATEWAY_CONTROL_TOKEN || !env.ACP_GATEWAY_ROOT_ID) {
    try {
      stored = JSON.parse(readFileSync(statePath, "utf8"))?.identity ?? null;
    } catch {}
  }
  const token = env.ACP_GATEWAY_CONTROL_TOKEN ?? stored?.token;
  const ownerRootId = env.ACP_GATEWAY_ROOT_ID ?? stored?.rootId ?? `main-${process.ppid}`;
  if (typeof token !== "string" || token.length < 24) {
    throw new Error(`No valid Gateway Control identity in ${statePath}; run acp-gateway-bootstrap first`);
  }
  if (typeof ownerRootId !== "string" || !ownerRootId) {
    throw new Error(`No valid Gateway root identity in ${statePath}; run acp-gateway-bootstrap first`);
  }
  return { token, rootId: ownerRootId, statePath };
}

export function rootId() {
  return process.env.ACP_GATEWAY_ROOT_ID || `main-${process.ppid}`;
}
