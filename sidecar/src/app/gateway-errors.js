// Korean wording for the Gateway errors a person can act on, chiefly the
// ones Gateway 1.8 added. The code stays beside the text so a report still
// names it; any other error keeps the Gateway's own message.
const MESSAGES = {
  SOCKET_UNTRUSTED: "Gateway 소켓 경로를 믿을 수 없어 연결하지 않았습니다. ACP_GATEWAY_SOCKET은 본인만 쓸 수 있는 폴더(또는 /tmp)에 있어야 합니다.",
  SOCKET_PATH_TOO_LONG: "Gateway 소켓 경로가 너무 깁니다(macOS는 103바이트까지). ACP_GATEWAY_SOCKET을 더 짧은 경로로 바꾸세요.",
  WORKER_CONTROL_DENIED: "Gateway Worker 안에서 시작된 프로세스라 Gateway를 제어할 수 없습니다.",
  DAEMON_IDENTITY_INVALID: "Gateway 데몬이 받은 identity가 올바르지 않습니다. ~/.acp-gateway/install.json을 확인한 뒤 Gateway를 다시 시작하세요.",
  CONTROL_ACCESS_DENIED: "Gateway가 AgenLynk의 토큰을 거부했습니다. 토큰을 막 교체했다면 Gateway가 아직 이전 토큰으로 실행 중입니다. 작업이 끝난 뒤 설정에서 Gateway를 다시 시작하세요.",
  STATE_SNAPSHOT_CORRUPT: "Gateway가 상태 스냅샷을 읽지 못해 시작하지 않았습니다. 백업에서 스냅샷을 되살리거나 ACP_GATEWAY_STATE_RECOVERY=snapshot-drop(또는 cold)로 시작하세요.",
  STATE_DIR_LOCKED: "다른 Gateway가 같은 상태 폴더를 쓰고 있습니다. 실행 중인 Gateway를 하나만 남기세요.",
  NOT_SESSION_OWNER: "다른 Main이 연 세션이라 이 요청으로는 다룰 수 없습니다."
};

/** The message to show for `error`: Korean with the code for a known Gateway error, else its own. */
export function describeGatewayError(error) {
  const code = typeof error?.code === "string" ? error.code : null;
  const known = code ? MESSAGES[code] : null;
  if (known) return `${known} (${code})`;
  return error?.message ?? String(error);
}
