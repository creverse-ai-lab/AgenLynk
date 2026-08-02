---
name: agent-delegator
description: Delegate, monitor, resume, and control bounded work through the local ACP Gateway. Use from an interactive Main agent when a user asks to send work to an installed ACP worker; select a worker model or permission policy; continue a persistent worker session; handle worker permission or structured input requests; or collect delegated results through agent_acp_* MCP tools.
---

# Agent Delegator

Use the Main-only `agent-acp` MCP. Do not inject that Control MCP into worker sessions or ask a worker to control sibling sessions.

## Delegate work

1. Call `agent_acp_setup` without a provider to inspect installed providers without starting them. Always surface every non-empty `alerts` entry to the user before delegating. Use `refreshAgentUpdates: true` when the user requests a fresh health or ACP version check. Then call setup with one explicit provider when that worker must be initialized.
2. Open a session with `agent_acp_session_open`. Always provide:
   - `provider`: one installed provider ID returned by setup, such as `claude`, `grok`, `codex`, or `auggie`.
   - `cwd`: the narrowest working directory needed.
   - `model`: the model requested by Main when known.
   - `permissionPolicy`: `read_only` for analysis/review, `ask` for approval-gated changes, or `auto_approve` only when the user authorized unrestricted changes within the session roots.
3. Send a bounded task with `agent_acp_prompt`. State the expected artifact or output and validation requirement.
4. Poll with a cursor and preserve every returned `nextCursor`.
   - While running, use `waitMs` and `includeResult: false` to avoid retransmitting the cumulative response.
   - A poll wait ending is not a worker execution timeout. Continue until a terminal or Main-input status is returned.
   - Request `includeResult: true` when the turn becomes `idle`, `error`, or `cancelled`.
5. Review the result and any artifacts yourself before accepting delegated work.

## Handle large results

- When a result is likely to be large and the permission policy allows writes, ask the Worker to write the complete deliverable inside the task `cwd` and return a concise summary plus its absolute path. Do not request a file write in `read_only` mode.
- Keep intermediate polls on `includeResult: false`. At a terminal status, inspect `result.artifact` or `resultArtifact` as well as the inline tail.
- The Gateway spills an oversized result or terminal output to a Gateway-owned artifact file. Use the returned `path`, `bytes`, `complete`, `truncated`, and optional `error` metadata; accept the file only when `complete` is true, `path` is present, and `truncated` is false. Otherwise disclose the incomplete result.
- Read only the needed portions of a large artifact when reviewing it. A protocol frame that exceeds the hard frame limit is rejected rather than written as an artifact.

## Handle Main input

- On `waiting_permission`, inspect the request through poll events or `agent_acp_inbox`, then answer with `agent_acp_permission`. Main owns the decision; never let the worker self-approve an `ask` request.
- On `waiting_input`, answer, decline, or cancel with `agent_acp_answer` using the worker's `requestId`.
- On an invalid, unsafe, or obsolete turn, call `agent_acp_cancel` and continue polling until cancellation completes.

## Continue or finish

- Keep the Gateway `sessionId` when follow-up work is likely. A disconnected resumable session is restored when prompted again.
- Use `agent_acp_session` with `pin` only for deliberately long-lived or temporarily unattended work; otherwise allow normal retention cleanup.
- Use `close` for disposable completed sessions and `clean` for expired owned sessions.
- Use `agent_acp_session` with `list` or `get` before creating a duplicate session for the same continuing task.

## Guardrails

- Keep provider choice, model choice, permission policy, and worker MCP options under Main control.
- Send only task-relevant repository material to an external provider.
- Do not expose the Gateway Control token, Main root ID, or socket path to a worker.
- Do not treat worker confidence or test claims as proof; validate according to the task's risk.
