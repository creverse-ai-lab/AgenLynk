# Monitor characterization trace v2

각 `.ndjson` 파일은 다음 순서로 재생한다.

1. 첫 줄 `meta`: `traceVersion`, 고정된 `name`, 실제 코드를 실행할 `runner`. `maxEventsPerSession`이 있으면 runner가 그 cap으로 `MonitorState`를 만든다. `rootId`가 있으면 `/api/meta` identity를 그 값으로 고정한다.
2. 중간 줄: runner에 전달할 순서가 있는 입력 또는 checkpoint
3. 마지막 줄 `expected`: Node가 재생해 만든 완전한 snapshot의 부분 계약과, 그 생성본에서 뽑은 projection/transport/meta

Runner:

- `monitor-state`: `MonitorState`의 실제 mutation API를 순서대로 호출한다. `state.sessions`가 있으면 `setSessions` 후 현재 SSE `state` shape(`sessions`, `removedSessionIds`)을 기록한다.
- `socket-flow`, `gateway-rpc`: Phase 1에서 고정한 transport 입력/기대값이다. Gateway 구현이 공식 artifact로 이동한 Phase 4 이후 AgenLynk Node suite는 이를 재실행하지 않고 Swift decoder/selection 호환 검증에서만 소비한다. Gateway transport 동작 자체는 `agent_gateway`가 검증한다.

Node 재생 결과는 완전한 `MonitorState.snapshot()`이다. fixture `expected.snapshot`은 그 생성본의 부분 계약이다. Swift는 같은 입력 줄을 production decoder로 재생하고, `AppModel`이 쓰는 `MonitorSelection.reconcile` / `MonitorStreamNotice.forPausedSubscription`을 그대로 실행한다.

selection-reset은 live가 비어도 merged history에서 선택된 Frontdoor/event를 유지해야 한다. observer overflow는 connected + `streaming=false` + error 한 건만 notice로 남기고, 같은 문구를 연속으로 두 번 넣으면 notice log는 한 줄에 count=2로 접힌다. `kind: "notice"` 메시지는 없다.

이벤트 규칙 (Monitor API v2):

- 입력 줄은 sidecar가 Gateway에서 받는 원본 이벤트다. `MonitorState.pushEvent`가 이를 정규화(`sidecar/src/normalize/acp.js`)해 canonical 이벤트로 store에 upsert한다. 기대 snapshot의 이벤트는 canonical 형태(`kind`, store가 부여한 `sequence`, 안정적인 `id`)다.
- 같은 session에서 같은 Gateway `sequence`+`ts` 쌍은 replay 중복으로 버린다. sequence가 같아도 ts가 다르면 재시작한 daemon의 새 이벤트다.
- 같은 turn의 연속된 message/thought chunk는 이벤트 하나로 합쳐지고, 본문은 도착 순서가 아니라 Gateway sequence 순서로 만든다(gap replay가 앞 chunk를 늦게 다시 보내도 문장이 뒤섞이지 않는다).
- tool_call과 그 tool_call_update는 `toolCallId`로 이벤트 하나가 된다.
- session이 live에서 빠지면 session record만 history로 옮겨지고 이벤트는 store에 그대로 남는다. 세션당 `maxEventsPerSession`을 넘으면 가장 오래된(ts 기준) 이벤트를 버린다.
- `subscription_replay_truncated`는 timeline/notice가 아니라 diagnostics + degraded health다. `subscription_error`는 SSE `kind: "state"`로만 올라가고 `kind: "notice"`는 없다.
- `subscription-gap.ndjson`은 gap marker가 timeline에 저장되지 않고 degraded/reconciling 이후 healthy로 돌아오는지 확인한다.
- `event-flood.ndjson`은 순서가 뒤섞인 네 개의 서로 다른 이벤트를 한도 3에 넣어, 가장 오래된 것이 버려지고 replay 중복이 무시되는지 확인한다.

Swift는 v2부터 Gateway 원본 이벤트를 받지 않는다. Swift 쪽은 기대 snapshot을 production decoder로 읽고 selection/notice 로직만 재생한다.
