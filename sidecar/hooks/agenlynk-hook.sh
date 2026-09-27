#!/bin/sh
# AgenLynk monitoring hook for Claude Code, Codex and Grok.
#
# Forwards the hook event on stdin to the local AgenLynk sidecar so the
# dashboard sees tool calls, permission prompts and turn ends as they happen.
# Observe-only: it never prints a decision, always exits 0, and gives up in
# about a second when AgenLynk is not running, so it can never block or
# change what the agent does.
#
# Usage (registered by AgenLynk's hook installer): agenlynk-hook.sh claude|codex|grok

provider=${1:-}
case "$provider" in
  claude|codex|grok) ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

# Grok also runs the hooks in ~/.claude/settings.json; it reports through its
# own hook file, so the Claude registration stays quiet when Grok is the one
# running it (Grok sets GROK_HOOK_EVENT for every hook it runs). A Claude or
# Codex that merely runs inside a Grok shell only inherits GROK_SESSION_ID,
# and its hooks do report.
if [ "$provider" != "grok" ] && [ -n "${GROK_HOOK_EVENT:-}" ]; then
  cat >/dev/null 2>&1
  exit 0
fi

endpoint=${AGENLYNK_HOOK_ENDPOINT:-$HOME/.acp-gateway/agenlynk/hook-endpoint}
if [ ! -r "$endpoint" ]; then
  cat >/dev/null 2>&1
  exit 0
fi

# Parsed, never sourced: the endpoint file is data.
port=
token=
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in
    AGENLYNK_HOOK_PORT) port=$value ;;
    AGENLYNK_HOOK_TOKEN) token=$value ;;
  esac
done < "$endpoint"
case "$port" in
  ''|*[!0-9]*) cat >/dev/null 2>&1; exit 0 ;;
esac
case "$token" in
  ''|*[!A-Za-z0-9_-]*) cat >/dev/null 2>&1; exit 0 ;;
esac

# Lineage: the session ids the launching agents exported (an agent started
# from another agent's shell tool is that session's worker), Claude's
# entrypoint, and this hook's parent pid. Only these names are read, and
# only values of the id charset are sent; no other environment leaves here.
set -- -H "Content-Type: application/json" -H "X-AgenLynk-Hook-Token: ${token}"
id_ok() {
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}
if id_ok "${CLAUDE_CODE_SESSION_ID:-}"; then set -- "$@" -H "X-AgenLynk-Parent-Claude: ${CLAUDE_CODE_SESSION_ID}"; fi
if [ "$provider" != "grok" ] && id_ok "${GROK_SESSION_ID:-}"; then set -- "$@" -H "X-AgenLynk-Parent-Grok: ${GROK_SESSION_ID}"; fi
if [ "$provider" != "codex" ] && id_ok "${CODEX_THREAD_ID:-}"; then set -- "$@" -H "X-AgenLynk-Parent-Codex: ${CODEX_THREAD_ID}"; fi
if id_ok "${CLAUDE_CODE_ENTRYPOINT:-}"; then set -- "$@" -H "X-AgenLynk-Entrypoint: ${CLAUDE_CODE_ENTRYPOINT}"; fi
case "${PPID:-}" in ''|*[!0-9]*) ;; *) set -- "$@" -H "X-AgenLynk-Hook-Ppid: ${PPID}" ;; esac

curl -sS -X POST "http://127.0.0.1:${port}/api/hooks/${provider}" \
  --connect-timeout 0.3 --max-time 1 \
  "$@" \
  --data-binary @- >/dev/null 2>&1 || :
exit 0
