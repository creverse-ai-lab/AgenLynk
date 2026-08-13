# Monitor characterization trace v1

각 `.ndjson` 파일은 다음 순서로 재생한다.

1. 첫 줄 `meta`: `traceVersion`, 고정된 `name`, 실제 코드를 실행할 `runner`. `maxEventsPerSession`이 있으면 runner가 그 cap으로 `MonitorState`를 만든다. `rootId`가 있으면 `/api/meta` identity를 그 값으로 고정한다.
2. 중간 줄: runner에 전달할 순서가 있는 입력 또는 checkpoint
3. 마지막 줄 `expected`: Node가 재생해 만든 완전한 snapshot의 부분 계약과, 그 생성본에서 뽑은 projection/transport/meta

Runner:

- `monitor-state`: `MonitorState`의 실제 mutation API를 순서대로 호출한다. `state.sessions`가 있으면 `setSessions` 후 현재 SSE `state` shape(`sessions`, `removedSessionIds`)을 기록한다.
- `socket-flow`, `gateway-rpc`: Phase 1에서 고정한 transport 입력/기대값이다. Gateway 구현이 공식 artifact로 이동한 Phase 4 이후 AgenLynk Node suite는 이를 재실행하지 않고 Swift decoder/selection 호환 검증에서만 소비한다. Gateway transport 동작 자체는 `agent_gateway`가 검증한다.

Node 재생 결과는 완전한 `MonitorState.snapshot()`이다. fixture `expected.snapshot`은 그 생성본의 부분 계약이다. Swift는 같은 입력 줄을 production decoder로 재생하고, `AppModel`이 쓰는 `MonitorSelection.reconcile` / `MonitorStreamNotice.forPausedSubscription`을 그대로 실행한다.

selection-reset은 live가 비어도 merged history에서 선택된 Frontdoor/event를 유지해야 한다. observer overflow는 connected + `streaming=false` + error 한 건만 notice로 남기고, 같은 문구를 연속으로 두 번 넣으면 notice log는 한 줄에 count=2로 접힌다. `kind: "notice"` 메시지는 없다.

이벤트 규칙 (현재 동작):

- live `pushEvent`는 sequence로 정렬한 뒤 cap한다. 같은 session의 같은 finite sequence는 중복으로 버리고 넣지 않는다.
- session이 live에서 빠지면 이벤트가 있을 때만 history로 아카이브하고, history도 sequence 다음 `ts`로 정렬한 뒤 최근 `maxEventsPerSession`개만 남긴다.
- live cap도 같은 한도로 가장 오래된 이벤트를 버린다.
- `subscription_replay_truncated`는 timeline/notice가 아니라 diagnostics + degraded health다. `subscription_error`는 SSE `kind: "state"`로만 올라가고 `kind: "notice"`는 없다.
- `subscription_gap.ndjson`은 gap marker가 timeline에 저장되지 않고 degraded/reconciliation을 거쳐 replay 후 canonical 순서로 복구되는 계약을 고정한다.
- `event-flood.ndjson`은 중복·역순 이벤트와 bounded overflow diagnostics를 고정한다.

재현성을 위해 timestamp는 고정 ISO-8601 문자열만 사용한다. PID, 실제 임시 경로, 현재 시각, map iteration에 의존하는 값은 fixture에 기록하지 않는다.
