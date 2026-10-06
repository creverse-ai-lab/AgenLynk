# ACP Gateway 1.5.2 프롬프트 검토 보고서

- 대상: `creverse-ai-lab/agent_gateway` v1.5.2 (`336bad2`)
- 검토자: Claude, Codex, Grok. 세 검토 모두 읽기 전용이었다.
- 범위: 에이전트 컨텍스트에 들어가는 문장 전부
  - `skills/agent-delegator/`: SKILL.md, references 5개, `agents/openai.yaml`. 설치기가 모든 CLI에 배포한다.
  - Control MCP(`agent-acp`, Frontdoor 전용) 도구 12개의 description과 inputSchema: `src/index.js` 253–451행
  - Guide MCP(`agent-acp-guide`, 모든 CLI): `src/guide.js`, `src/gateway-service.js`의 `guide()`
- 코드 대조: 아래 표의 "근거" 열에 적은 곳은 제가 소스에서 다시 확인했다.
- 결론: **프롬프트를 고치기 전에 먼저 막아야 할 문제가 세 가지 있다.** 셋 모두 에이전트가 없는 것을 찾거나, 작업을 두 번 돌리거나, 권한 범위를 잘못 믿게 만든다. 그다음은 토큰 절감이다. Main의 턴당 비용을 약 25–35% 줄일 수 있다.

## 1. 크기 (항상 로드되는 표면)

| 표면 | 크기 | 약 토큰 | 들어가는 시점 |
|---|---:|---:|---|
| Control 도구 정의 12개 전체 | ~12.0KB | ~3,000 | Frontdoor의 매 턴 |
| ├ `agent_acp_poll` | ~2.9KB | | 가장 큼 |
| └ `agent_acp_run` | ~2.6KB | | |
| SKILL.md 본문 | 9.1KB | ~2,300 | 트리거된 뒤 계속 남음 |
| SKILL.md `description` | 439B | ~110 | Worker를 포함한 **모든 CLI**의 매 턴 |
| `guide()` 응답 | ~0.8–1.2KB | ~200–300 | 호출 시. 호스트에 따라 JSON이 두 번 들어감 |
| references 5개 | 16.7KB | ~4,200 | 필요할 때만 |

Control MCP와 Guide MCP 모두 서버 `instructions`가 없다. 세 검토자 모두 지금처럼 두는 것이 맞다고 봤다.

## 2. 가장 먼저 고칠 것 (심각도 높음)

| # | 문제 | 근거 | 합의 | 수정안 |
|---|---|---|---|---|
| H1 | **존재하지 않는 스킬 `$multi-agent-routing`에 의존한다.** description은 "Use after multi-agent-routing selects…"이고, 본문 첫 줄은 "Run `$multi-agent-routing` first"다. 설치기는 `agent-delegator`만 배포하고, 이 머신의 `~/.claude`·`~/.codex`·`~/.grok` 스킬 폴더 어디에도 이 스킬이 없다. 에이전트는 없는 스킬을 찾다 멈추거나, 이 스킬을 아예 트리거하지 않는다. 모델과 역할을 고를 책임도 누구에게도 없게 된다. | SKILL.md:3, 8 / installer.js | 3/3 | 의존을 지우고 라우팅을 본문에 흡수한다: "Choose the route here. Use a native subagent only when the host can run the routed model itself; otherwise continue with `agent_acp_*`. There is no separate routing skill." |
| H2 | **Worker에게도 설치되는데 "Worker면 쓰지 마라"는 가드가 없다.** 설치기는 발견한 모든 provider에 스킬을 넣는다. description의 일반 동사(delegate, coordinate, answer permissions 등)가 Worker 쪽 작업에서도 트리거된다. 본문에도 "`agent_acp_*`가 없으면 너는 Worker다"라는 판별이 없다. | SKILL.md:1–12 / installer.js:312 / README:514 | 3/3 | 본문 첫 줄에 "Main only. If `agent_acp_setup` is not in your tool list you are an ACP Worker: do not use this skill; do the task and tell your caller if it needs another agent."를 둔다. description 끝에는 "Not for Workers or native subagents."를 붙인다. openai.yaml `short_description`도 "Main-only: …"로 바꾼다. |
| H3 | **"검증 오류가 아니면 `{taskId}`로 재시도" 규칙이 핸들이 없는 경우를 막지 못한다.** 수락 RPC 타임아웃이나 progress 미수신이면 `taskId`가 없다. 그런데 `idempotencyKey`는 "비쌀 때만" 권장해서 가장 흔한 무핸들 구간이 무방비다. `PERSISTENCE_UNHEALTHY`, `PROMPT_TOO_LARGE`, `UNKNOWN_TASK`는 붙을 핸들 자체가 없어서 규칙과 충돌한다. | SKILL.md:48, 54 / index.js:337 / recovery.md:5–19 | 3/3 | "Always pass an `idempotencyKey` on a start. Holding a `taskId` → retry only as `{taskId}`. No handle yet → repeat the start with the same key, prompt and model (it attaches). `PROMPT_TOO_LARGE`, `PERSISTENCE_UNHEALTHY`, `UNKNOWN_TASK` have nothing to attach to — see recovery.md." 이 문장은 매 턴 보이도록 `agent_acp_run` description에 남긴다. |
| H4 | **`IDEMPOTENCY_CONFLICT` 조건이 틀렸다.** 스킬은 "different prompt"라고 하지만 실제 digest는 `{prompt, model}`이다. 충돌 시 `details.taskId`에 기존 핸들이 오는데 스킬은 "새 키를 쓰라"고만 한다. 그래서 재시도 중 문구를 고친 모델이 두 번째 턴을 연다. 이 문장은 권한 정책 문단(2절)에 잘못 들어가 있다. | SKILL.md:40 / gateway-service.js:3124 | 3/3 | 3절로 옮긴다: "Same key with a different prompt or model → `IDEMPOTENCY_CONFLICT`; attach to `details.taskId`. A new key is only for new work." |
| H5 | **`agent_acp_answer`에서 `action`을 빼면 `accept`가 된다.** 가장 위험한 기본값인데 스키마의 `required`에 `action`이 없다. `agent_acp_permission`에서 `optionId`를 빼면 취소된다는 사실도 스키마에 적혀 있지 않다. | index.js:383–407 / gateway-service.js:1779 (`args.action ?? "accept"`) | Codex, Grok | 스키마에서 `action`을 required로 하고, 하위 호환이 걱정되면 런타임 기본값을 `cancel`로 바꾼다. `optionId` 설명에는 "missing = cancels"를 적는다. **프롬프트가 아니라 코드 변경이다.** |
| H6 | **권한 경계를 실제보다 강하게 말한다.** "Reads outside the roots and of Gateway files are refused automatically for the other providers"라고 하지만, Claude는 `read_only`일 때만 루트 밖 읽기를 막는다(`ask`면 권한 요청이 된다). 경로를 판별할 수 없는 셸 명령은 `auto_approve`에서 그대로 승인된다. Codex의 `read_protected`가 `~/.acp-gateway`(Control 토큰 위치)까지 포함한다는 점도 드러나지 않는다. | SKILL.md:38–40 / providers.js:214–276 | Codex, Grok (Claude는 "대체로 맞다"로 봄) | "Treat every `relevantAlerts[].scope` entry as possible. Codex `read_protected` includes `~/.acp-gateway`; do not feed it untrusted text on a machine holding the Control token. Other providers refuse protected paths; reads outside the roots are refused only under `read_only`." |

## 3. 정확성과 모순 (심각도 중간)

| # | 문제 | 근거 | 수정안 |
|---|---|---|---|
| M1 | 바인딩 절차가 실행 불가능하다. `setup {mode:"summary"}`의 provider 항목은 `{provider, ok, started}`뿐이고 `model`이 없다. provider별 setup은 Claude·Codex에서 `model: null`이라, 호출해도 프로세스만 띄울 뿐이다. 절 제목도 번호 없는 "Bind…" 다음에 "1."이 온다. | SKILL.md:14–30 / gateway-service.js:604–619 | 두 절을 "1. Bind"로 합친다: "summary once to pick an `ok` provider → pass the exact model to `session_open` → verify returned `model`, stop on mismatch." |
| M2 | model option을 광고하지 않는 provider에 `model`을 넘기면 `INVALID_ARGUMENT`다. 설치본에 있던 이 경고가 1.5.2에서 빠졌다. | gateway-service.js:1000–1005 | "INVALID_ARGUMENT about model options → omit `model`, accept the default only if it equals the routed model." |
| M3 | `agent_acp_run`의 terminal 목록이 `idle/cancelled/error`뿐이다. 실제로는 `disconnected`, `failed`, `ok:false`, `incomplete:"wait_abandoned"`도 온다. | SKILL.md:49–52 / index.js:172–178 | "`working`(any `incomplete`) → attach; `input_required` → answer then attach; anything else is terminal — check `ok`, `error`, `result`." |
| M4 | poll 기본 동작 설명이 틀렸다. `waitMs` 기본값은 0이라 기다리지 않는다. `waitMs`를 주면 상태가 조금만 바뀌어도(예: `waiting_permission`) 돌아온다. | SKILL.md:65 / gateway-service.js:1627–1651 | 정확한 한 줄로 바꾼다. 4절 전체는 diagnostics.md로 내린다(T3). |
| M5 | `staleFrontDoor`는 버전이 "다를 때" 붙는다. 스킬은 "cached schema is older"라고 해서 방향을 한쪽으로만 말한다. recovery.md와 순서도 다르고, `session_restore`가 빠져 있다. | SKILL.md:34 / index.js:213–223 | "Versions differ (not semver). Update the Gateway, then reconnect `agent-acp`. Set on setup, session_open, session_restore." |
| M6 | task-semantics.md는 `ttl`·`pollInterval`을 tool 인자에 넣지 말라고 한다. 그런데 `agent_acp_run` 스키마가 두 필드를 인자로 받는다. | task-semantics.md:31 / index.js:352 | "Direct call: ordinary `agent_acp_run` args. Host Task mode: the request's `task` object." |
| M7 | `UNKNOWN_TASK`면 곧바로 다시 실행하라고 한다. 하지만 TTL은 핸들만 지우고 턴은 계속 돌 수 있어서 중복 실행 위험이 있다. | recovery.md:13–20 / task-store.js:474 | "Handle expired only: check session/poll/inbox first; re-run with a new key only if the turn is inactive and no result is retrievable." |
| M8 | guide가 호출자와 상관없이 `role:"worker"`를 반환한다. Guide는 Frontdoor에도 설치되므로 Main이 부르면 자기 역할을 의심하게 된다. 온라인과 오프라인일 때 `rule` 문구도 다르다. `providers`에는 설치 명령과 홈 절대경로가 들어 있다. | gateway-service.js:579–587 / guide.js:12, 26–32 | 응답을 최소화한다: `{ok, controlAvailable:false, rule, providers:[{id, ok}]}`. `rule`은 상수 하나로: "If `agent_acp_*` tools are in your list you are Main — use them; otherwise you are a Worker: finish the task and report to your caller." description: "Worker check; cannot control agents." |
| M9 | 병렬 fan-out을 "짧게 기다리며" 하나씩 시작하면 뒤쪽 branch의 시작이 늦어진다. `waitMs:0`이면 핸들을 즉시 받는다. | multi-worker.md:3–5 / gateway-service.js:1157 | "Start every branch with `waitMs:0`, collect all `taskId`s, then attach to each." |
| M10 | 아티팩트 포인터를 "guaranteed"라고 한다. spill에 실패하면 포인터 없이 `resultDegraded:true`가 온다. | index.js:346, 376 / response-profile.js:103–115 | "If `textArtifact` is absent/incomplete or `resultDegraded`, treat the result as incomplete." |
| M11 | 네이티브 예외가 Codex 전용 모델명(`gpt-5.6-sol`·`terra`)으로 박혀 있어, Claude·Grok이 Frontdoor일 때는 의미가 없다. `grok-4.5`를 read-only red-team으로 고정한 줄은 실행 스킬에 섞인 라우팅 정책이다. | SKILL.md:10, 19 | H1에서 라우팅을 흡수할 때 "host-native if possible"과 "Default: Grok reviews read-only (process-scoped: model change = new session)"로 정리한다. |
| M12 | README의 기본 절차가 아직 `prompt` + `poll`이다. README가 가리키는 표 제목("Retrieve the correct result")도 스킬에 없다. | README:184–200 | 4–5단계를 `agent_acp_run` / `{taskId}` attach로 바꾸고, 참조를 `references/artifact-retrieval.md`로 맞춘다. |

## 4. 토큰 절감 (심각도 낮음, 효과는 큼)

| # | 조치 | 효과 |
|---|---|---|
| T1 | 같은 규칙이 도구 설명, SKILL, reference에 3–4번 반복된다: never resend, compact 프로필, `totalBytes`와 `transcriptBytes`, Worker 결과 검토. 도구에는 호출에 필요한 불변 의미 한 줄만 남기고, 판단 규칙은 SKILL에, 세부는 reference에 둔다. | 도구 정의 −2KB |
| T2 | poll의 `responseProfile` 설명(~420B)을 "current(default) / compact: no session envelope / diagnostic: queue, pending counts. Check `responseProfiles`."(~130B)로 줄인다. run 쪽은 "shapes `result` only"로 둔다. run과 poll의 동작 차이는 diagnostics.md에 적는다. | −0.5KB |
| T3 | SKILL 4절(Poll, ~1.5KB)을 diagnostics.md로 옮긴다. 기본 경로(`agent_acp_run`)는 poll이 필요 없다. | −1.5KB |
| T4 | 1.4.0/1.5.0 deprecation 이력과 "unpaged 1.3.x"를 지운다. `agent_acp_prompt` 설명에 "Legacy: acknowledgement only; prefer `agent_acp_run`"을 적고, 도구 배열에서 run 뒤로 옮긴다. | 오선택 방지 |
| T5 | description을 439B에서 ~300B로 줄인다. 동사 나열을 빼고, 판별 조건(Main-only, non-native worker, `agent_acp_setup` 존재)만 남긴다. | 모든 CLI 매 턴 |
| T6 | 스키마 설명이 빠진 곳을 채운다: `permissionPolicy` enum 의미, `mcpServers`("Worker tools only; never agent-acp"), `session_open` 반환값(model 검증). | +0.3KB, 안전성 ↑ |
| T7 | `session_open`과 `session_restore`의 `thoughtCapture` 설명이 중복된다. restore 쪽은 "same as open; omitted = stored value"로 줄인다. | 소량 |

추정치(바이트÷4):

| 대상 | 지금 | 적용 후 |
|---|---:|---:|
| Control 도구 정의 | ~3,000 tok | ~2,100–2,500 tok |
| SKILL.md 본문 | ~2,300 tok | ~1,400–1,700 tok |
| guide 응답 | ~200–300 tok | ~75 tok |

- Main이 스킬을 연 턴 합계: 약 5,200–6,300 tok에서 3,700–4,300 tok으로, **약 25–35% 감소**
- 스킬을 로드하지 않은 턴: 약 500 tok 감소
- Worker CLI: 매 턴 description이 약 35 tok 감소

## 5. 이 머신의 설치 상태 (AgenLynk에서 확인)

- `~/.claude`·`~/.codex`·`~/.grok`의 `agent-delegator`는 8/30 설치본으로, 세 벌이 서로 같다. 1.5.2와는 **SKILL.md만** 다르고, references와 openai.yaml은 같다.
- 설치본에는 `permission_policy_partial`, `workspace:"snapshot"`, `IDEMPOTENCY_CONFLICT` 문단이 없다. 또 prompt-level `model`이 "one turn"만 유지된다고 적혀 있는데, 스키마는 "this and following turns"다.
- AgenLynk가 Gateway 1.5.2를 적용할 때 `--update-skill`이 돌아야 이 차이가 해소된다. 1.5.2로 올린 AgenLynk 빌드에서 앱을 재시작한 뒤 스킬이 갱신됐는지 확인해야 한다.

## 6. 문제없다고 확인한 부분 (세 검토자 공통)

- 스킬에 나오는 필드명과 오류 코드는 모두 실제로 존재한다: `next.answerWith`, `relevantAlerts`/`alertsOmitted`, `limits`, `responseProfiles`, `optionsOmitted`, `resultDegraded`, `workspace_diff`, `SESSION_ACTIVE`·`PROMPT_TOO_LARGE`·`PERSISTENCE_UNHEALTHY`·`UNKNOWN_TASK`·`IDEMPOTENCY_CONFLICT`.
- 다음 값들이 구현과 같다.
  - active 상태 5개(`running`, `waiting_permission`, `waiting_input`, `cancelling`, `restoring`)
  - `waitMs`: 기본 55000, 상한 600000, 첫 실행 권장 25000
  - `resultBudgetBytes`: 0–65536
  - 대기 포기(abort)는 턴 취소가 아니라는 설명
- 같은 세션, 같은 키, 같은 prompt와 model이면 기존 핸들에 붙는다. prompt-level `model`이 이후 턴에도 유지된다는 설명(1.5.2 본문)도 맞다.
- Worker에 `agent-acp`를 주입하려 하면 런타임이 거부한다. Guide 프로세스에는 Control 토큰이 없다. 역할 분리의 "코드" 쪽은 안전하고, 문제는 "문장" 쪽이다.
- references를 상황별 5개로 나눈 구조는 유지할 만하다.

## 7. 권장 작업 순서

1. **코드 한 건 (H5)**: `agent_acp_answer.action`을 required로 하거나 기본값을 `cancel`로 바꾼다. 안전성 문제라 가장 먼저 한다.
2. **스킬 핵심 (H1–H4, H6)**: routing 의존 제거, Worker 가드, 재시도·idempotency 규칙, 권한 범위 문구. SKILL.md 약 10곳이다.
3. **정확성 (M1–M12)**: 바인딩 절 병합, terminal 목록, poll 설명, guide 응답 최소화.
4. **토큰 (T1–T7)**: 도구 설명 축약, 4절 이동, 레거시 문구 제거.
5. **배포 확인**: Gateway 릴리스 후 AgenLynk에서 `--update-skill`로 세 CLI의 스킬이 갱신되는지 확인한다.
