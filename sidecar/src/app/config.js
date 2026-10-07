import { tmpdir } from "node:os";
import { join } from "node:path";

const uid = typeof process.getuid === "function" ? process.getuid() : "user";

export function gatewaySocketPath() {
  return process.env.ACP_GATEWAY_SOCKET || join(tmpdir(), `acp-gateway-${uid}.sock`);
}
