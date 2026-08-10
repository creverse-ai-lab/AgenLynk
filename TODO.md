# ACP Gateway / Lynk v1 TODO

기준 커밋: `baef4fb` (`feat: expand Lynk monitoring and agent management`)

## v1 목표

Lynk DMG를 설치한 라이트 사용자가 터미널이나 별도 Node 설치 없이 ACP Gateway를 시작할 수 있게 한다. Gateway는 Lynk와 분리된 독립 모듈로 설치·업데이트하고, Swift UI는 버전이 명시된 Monitor API만 사용한다. Pet과 제3자 UI는 Gateway 제어 권한 없이 버전된 JSON 상태·표현 action을 소비한다.

```text
Lynk.app (thin Swift UI)
  -> Monitor API v1 (loopback HTTP/SSE)
  -> installed Gateway runtime/current
  -> Gateway daemon + ACP adapters

Monitor activity projection
  -> pet-state.json
  -> pet-actions.json
  -> CodexPet 또는 사용자 제작 renderer
```

## 확정한 경계

- [x] Gateway 실행 코드는 앱 번들에서 직접 실행하지 않고 단일 설치 경로에서만 실행한다.
- [x] 설치 경로는 `~/.acp-gateway/runtime/versions/<version>-<buildId>/`로 정의한다.
- [x] `~/.acp-gateway/runtime/current.json`을 원자적으로 교체해 활성 버전을 선택한다.
- [x] DMG에는 최초 설치용 Gateway seed와 Node runtime을 포함하지만, 첫 실행 때 독립 runtime 경로로 설치한 뒤 그 설치본만 실행한다.
- [x] `install.json`, Gateway state, socket path는 유지해 기존 사용자의 세션과 identity를 보존한다.
- [ ] Swift UI는 Gateway 내부 파일이나 socket RPC shape에 직접 의존하지 않고 Monitor API v1만 사용한다.
- [ ] Pet action은 `thinking`, `tool`, `waiting`, `completed` 같은 표현용 데이터다. Pet에서 Gateway로 명령을 보내는 action channel은 v1에 포함하지 않는다.
- [ ] UI, Gateway, Monitor API, Pet contract 버전은 서로 독립적으로 관리한다.

## P0 — 계약과 호환성 고정

### Gateway handshake

- [x] Gateway `setup` 응답에 `gatewayApiVersion`, `gatewayVersion`, `gatewayBuildId`, `runtimeRoot`, `capabilities`를 추가한다.
- [x] `gatewayApiVersion`은 ACP protocol 버전과 별도 상수로 관리한다.
- [ ] 같은 API major에서 필드 추가는 허용하고, 삭제·이름 변경·의미 변경은 major를 올린다.
- [x] 클라이언트는 모르는 capability와 필드를 무시하고, 지원하지 않는 API major만 명시적으로 거부한다.
- [x] `gatewayBuildId` 동일성 검사는 같은 `runtimeRoot`의 stale process 판정에만 사용한다.
- [x] 독립 릴리스된 UI와 Gateway 사이에서 build ID가 다르다는 이유만으로 재시작하지 않는다.
- [x] 호환되지 않는 경우 구조화된 error code와 필요한 최소 버전을 반환한다.

### Monitor API v1

- [ ] `monitor_ready`에 `monitorApiVersion`, `gatewayApiVersion`, `gatewayVersion`, `gatewayBuildId`, `capabilities`를 추가한다.
- [ ] `/api/meta`를 추가해 UI가 snapshot을 읽기 전에 호환성을 확인하게 한다.
- [ ] `/api/snapshot`과 SSE `state`/`event` payload에 `schemaVersion: 1`을 추가한다.
- [ ] error 문자열 비교로 구버전 기능을 판별하는 코드를 capability 판별로 교체한다.
- [ ] 인증 실패, 호환성 실패, 미설치, 업데이트 필요, restart blocked를 안정된 error code로 구분한다.
- [ ] Swift가 지원하지 않는 schema를 받으면 데이터를 부분 decode하지 않고 업데이트 안내 상태를 표시한다.

### 계약 fixture

- [ ] `test/fixtures/contracts/`에 Gateway setup, Monitor meta/snapshot/SSE fixture를 추가한다.
- [ ] Node 테스트와 Swift 테스트가 동일 fixture를 각각 encode/decode한다.
- [ ] 이전 minor fixture를 새 consumer가 계속 읽는 호환성 테스트를 추가한다.
- [ ] 필수 필드 누락, 잘못된 major, unknown additive field를 각각 테스트한다.

## P0 — Gateway 독립 runtime 모듈

### Runtime artifact

- [x] Gateway release artifact의 포함 범위를 `src/`, `skills/`, `package.json`, `package-lock.json`, production `node_modules`로 정의한다.
- [x] artifact에 `runtime-manifest.json`을 포함한다.
- [ ] manifest에 `gatewayVersion`, `gatewayBuildId`, `gatewayApiVersion`, `nodeVersion`, 파일 SHA-256 목록을 기록한다.
- [x] seed artifact와 설치된 artifact가 동일 manifest 검증 코드를 사용하게 한다.
- [ ] 개발 checkout, DMG seed, 설치 runtime을 구분하는 `runtimeSource` 값을 정의한다.

### Runtime resolver

- [ ] `src/runtime-layout.js`에 runtime root, versions, current pointer, staging, previous 경로 계산을 모은다.
- [ ] `src/runtime-resolver.js`가 `current.json`과 manifest를 검증하고 실행할 Node·daemon·monitor·bootstrap 경로를 반환하게 한다.
- [ ] `GatewayRpcClient` daemon autostart가 `import.meta.url` 옆 daemon 대신 resolver 결과만 실행하게 한다.
- [ ] CLI bin, bootstrap, monitor sidecar가 같은 resolver를 사용하게 한다.
- [x] Swift `SidecarController`가 번들 `src/monitor.js`를 직접 실행하지 않고 설치 runtime의 monitor entrypoint를 실행하게 한다.
- [x] 앱 번들 runtime fallback은 seed 설치에만 사용하고 daemon autostart에는 사용하지 않는다.
- [ ] socket을 이미 점유한 daemon의 `runtimeRoot`와 current runtime을 비교해 split-brain을 탐지한다.

### 기존 설치 migration

- [ ] 기존 `~/.acp-gateway/install.json` schema를 additive하게 확장한다.
- [ ] `install.json.runtime`에 current/previous version, build ID, runtime root, source를 기록한다.
- [ ] 기존 git checkout 설치를 첫 versioned runtime으로 가져오는 migration dry-run을 제공한다.
- [ ] 기존 identity token, rootId, gateway config, provider registry, state를 변경하지 않는다.
- [ ] migration 실패 시 기존 checkout daemon 실행 경로가 계속 동작하게 한다.
- [ ] migration을 두 번 실행해도 중복 설치나 identity rotation이 발생하지 않는지 테스트한다.

## P0 — 원자적 업데이트와 롤백

### Update abstraction

- [ ] `GatewayRuntimeUpdater` 인터페이스를 정의한다: `inspect`, `stage`, `validate`, `activate`, `rollback`, `prune`.
- [ ] 새 버전은 `runtime/staging/<id>/`에서만 설치·검증한다.
- [ ] manifest와 모든 파일 checksum을 검증한 뒤에만 versions 경로로 이동한다.
- [ ] staging runtime에서 dependency/runtime smoke test와 `npm run ci`를 실행한다.
- [ ] 활성화는 `current.json` 원자적 교체 한 번으로 완료한다.
- [ ] 이전 current를 `previous`로 기록하고 최소 1개, 최대 2개 known-good runtime을 유지한다.
- [ ] 활성화 후 daemon health가 version/build/API 조건을 만족하지 않으면 previous로 자동 복구한다.
- [ ] 진행 중 session, Task, Inbox가 있으면 기존 restart blocker 규칙으로 활성화를 보류한다.
- [ ] UI와 CLI가 동일 updater를 호출하고 동일 결과 JSON을 받게 한다.

### 업데이트 공급 경계

- [ ] 현재 `git pull -> npm ci` 흐름은 개발자용 `--dev-source-update`로 명시한다.
- [ ] 소비자용 runtime을 git checkout에서 in-place 수정하지 않는다.
- [ ] v1은 사용자 요청 기반 install/update/repair만 제공하고 백그라운드 Gateway 자동 업데이트는 켜지 않는다.
- [ ] 네트워크 runtime 업데이트를 열기 전 서명된 manifest 검증과 rollback 테스트를 release gate로 둔다.
- [ ] 검증되지 않은 URL, 로컬 임의 archive, 다른 repository origin을 UI 업데이트 경로에서 받지 않는다.
- [ ] 실패 결과에 현재 버전, 시도 버전, rollback 결과, 복구 방법을 포함한다.

### Update tests

- [ ] 새 runtime 검증 실패 시 current가 바뀌지 않는지 테스트한다.
- [ ] current 교체 후 health mismatch가 발생하면 previous로 복구되는지 테스트한다.
- [ ] UI 업데이트 후 Gateway가 유지되고, Gateway 업데이트 후 UI 재설치가 필요 없는지 테스트한다.
- [ ] 오래된 daemon이 socket을 점유한 경우 잘못된 번들 daemon을 추가 spawn하지 않는지 테스트한다.
- [ ] 앱 종료 시 sidecar와 renderer만 종료되고 Gateway daemon은 유지되는지 테스트한다.

## P0 — Swift abstraction과 라이트 사용자 onboarding

### Swift abstraction

- [ ] `GatewayRuntimeManaging` protocol을 정의해 설치 상태, 버전, install/update/repair/rollback을 추상화한다.
- [ ] `MonitorTransporting` protocol을 정의해 meta, snapshot, stream, config mutation을 추상화한다.
- [ ] `AppModel`에서 process/path/HTTP 세부 처리를 위 두 abstraction 뒤로 이동한다.
- [ ] UI가 `notInstalled`, `installing`, `ready`, `updateAvailable`, `incompatible`, `repairable`, `failed` 상태만 소비하게 한다.
- [ ] Gateway 설정과 에이전트 설치는 capability가 있을 때만 UI에 노출한다.
- [ ] Gateway 내부 오류 원문 대신 구조화된 사용자 메시지와 진단 상세를 분리한다.

### First-run flow

- [x] 앱 번들의 signed Node runtime을 설치 runtime의 기본 Node로 사용한다.
- [x] 시스템 Node 경로 입력은 개발자/고급 override로만 유지한다.
- [ ] 첫 실행에서 기존 Gateway 설치와 identity를 먼저 탐지한다.
- [x] 미설치이면 `seed 검증 -> runtime 설치 -> identity 생성 -> daemon health`를 한 흐름으로 수행한다.
- [x] Frontdoor(Codex/Claude/Grok) 선택과 MCP 등록은 설치 후 onboarding 또는 Settings에서 수행한다.
- [ ] MCP 등록 전 dry-run 계획을 UI에 표시한다.
- [x] 설치 중 실패하면 생성한 staging만 정리하고 기존 `~/.acp-gateway` 데이터는 보존한다.
- [ ] Settings에 설치 위치, Gateway/UI/API 버전, update/repair/rollback 상태를 표시한다.
- [x] 라이트 사용자는 터미널 없이 기본 설치를 끝낼 수 있게 한다.

### Fresh-machine acceptance

- [ ] macOS 14 Apple Silicon, Node 미설치 환경에서 DMG만으로 실행한다.
- [ ] 사용자 홈에 기존 `.acp-gateway`가 없는 상태에서 onboarding이 완료된다.
- [ ] Gateway daemon 재시작 후 Swift UI가 자동 재연결된다.
- [ ] 앱을 업데이트해도 설치된 Gateway 버전과 세션 state가 덮어써지지 않는다.
- [ ] 기존 CLI 설치 사용자가 앱을 설치해도 identity와 MCP 등록이 중복되지 않는다.

## P0 — Pet / custom UI JSON contract

### Contract files

- [ ] `contracts/pet/v1/pet-state.schema.json`을 추가한다.
- [ ] `contracts/pet/v1/pet-actions.schema.json`을 추가한다.
- [ ] 각 schema의 최소·전체 example JSON을 추가한다.
- [ ] `docs/pet-contract.md`에 필드, enum, 호환성, 보안 경계를 문서화한다.
- [ ] contract envelope를 `{ contract, version, generatedAt, producer, sequence, ... }`로 통일한다.
- [ ] v1에서 unknown field는 무시하고 unknown enum은 `unknown`으로 처리한다.

### State contract

- [ ] `pet-state.json`에 agent topology와 안정 상태만 기록한다.
- [ ] agent 필드를 `id`, `parentId`, `provider`, `model`, `role`, `state`, `updatedAt`, `attention`으로 정규화한다.
- [ ] `role`은 `frontdoor`, `worker`, `unknown`을 지원한다.
- [ ] `state`는 `offline`, `idle`, `starting`, `running`, `waiting`, `completed`, `failed`, `unknown`으로 고정한다.
- [ ] cwd 전체 경로와 prompt/task 원문은 기본 contract에서 제거하거나 privacy opt-in으로 제한한다.
- [ ] 기존 `inbox_pending`은 `attention`과 `pendingCount`로 명시적으로 표현한다.

### Presentation action contract

- [ ] `pet-actions.json`은 UI 표현을 위한 현재 action snapshot으로 정의한다.
- [ ] action enum을 `sleep`, `wake`, `think`, `useTool`, `waitForUser`, `celebrate`, `error`, `disconnect`, `unknown`으로 고정한다.
- [ ] 각 action에 `agentId`, `phase`, `changedAt`, `durationHintMs`, `priority`만 허용한다.
- [ ] Gateway 명령, shell command, file path, URL 실행, permission 응답을 action payload에 허용하지 않는다.
- [ ] 동일 Gateway activity를 메뉴바 UI, 기본 Pet, 제3자 renderer가 같은 action으로 해석하게 한다.
- [ ] 숫자 진행률은 제공하지 않고 phase, 경과 시간, 마지막 상태 변화만 제공한다.

### Projection과 renderer

- [ ] Swift의 private Pet 상태 매핑을 공통 activity projection 모듈로 이동한다.
- [ ] Monitor API가 normalized activity snapshot을 제공하고 Swift는 이를 다시 추론하지 않게 한다.
- [ ] state/actions 파일은 atomic write와 `0600` 권한을 사용한다.
- [ ] renderer 실행 계약은 executable path + `PET_STATE_FILE` + `PET_ACTIONS_FILE` 환경변수로 제한한다.
- [ ] CodexPet은 기본 renderer일 뿐 contract의 필수 구현으로 취급하지 않는다.
- [ ] 개발자 절대경로 기본값을 제거하고 비어 있는 기본값 또는 번들 renderer를 사용한다.
- [ ] Pet/renderer 환경에 Monitor API token, Gateway control token, install identity를 전달하지 않는다.
- [ ] 앱은 renderer가 생성한 action/control 파일을 읽지 않는다.

### Pet contract tests

- [ ] 현재 Frontdoor/Worker/inbox 매핑 테스트를 v1 fixture 기반으로 이전한다.
- [ ] 모든 상태가 정해진 state/action enum으로 매핑되는지 테스트한다.
- [ ] unknown additive field를 구 renderer가 무시할 수 있는지 테스트한다.
- [ ] renderer 환경에 secret이 포함되지 않는지 테스트한다.
- [ ] 임의 `pet-actions.json` 또는 action 입력 파일을 생성해도 Gateway mutation이 발생하지 않는지 테스트한다.
- [ ] 빠른 이벤트 갱신 중 JSON partial read가 발생하지 않는지 테스트한다.

## P1 — DMG release pipeline

- [ ] 앱 bundle에 Swift binary, icon, Node runtime, Gateway seed archive, 기본 Pet renderer를 배치한다.
- [ ] Gateway seed를 `Contents/Resources`에서 직접 실행하지 않는 packaging test를 추가한다.
- [x] arm64 Node binary와 nested helper를 먼저 Developer ID로 서명한다.
- [x] Lynk.app 전체를 hardened runtime으로 서명한다.
- [x] `codesign --verify --deep --strict` 검증을 release script에 추가한다.
- [x] `notarytool` 제출과 stapling을 자동화한다.
- [x] Applications 링크를 포함한 DMG를 생성한다.
- [ ] DMG checksum과 release manifest를 생성한다.
- [ ] Gatekeeper가 활성화된 깨끗한 Mac에서 설치·최초 실행·업데이트·rollback을 검증한다.
- [x] 개발용 ad-hoc build와 배포용 signed/notarized build 명령을 분리한다.

## Release gate

- [x] `npm test` 전체 통과.
- [x] `npm run macos:test` 통과.
- [x] `npm run macos:build` 통과.
- [ ] 계약 fixture를 Node와 Swift가 모두 decode.
- [ ] fresh-machine onboarding 통과.
- [ ] 기존 CLI 설치 migration 통과.
- [ ] Gateway 독립 update와 automatic rollback 통과.
- [ ] 앱 update가 Gateway runtime/current를 변경하지 않음.
- [ ] 제3자 sample renderer가 Pet JSON만으로 동작함.
- [ ] Pet renderer가 Gateway mutation 권한을 얻지 못함.
- [ ] signed/notarized DMG Gatekeeper 검증 통과.

## v1에서 하지 않을 것

- [ ] 범용 plugin registry 또는 plugin marketplace를 만들지 않는다.
- [ ] Pet에서 Gateway로 permission/config/restart/prompt 명령을 보내지 않는다.
- [ ] 원격 자동 업데이트 서버, delta update, stable/beta channel을 만들지 않는다.
- [ ] 앱 번들 runtime이 설치 runtime을 무시하고 daemon을 실행하지 않는다.
- [ ] 개발자용 `git pull` 업데이트를 라이트 사용자 UI에 노출하지 않는다.
- [ ] 신뢰할 수 없는 renderer를 자동 탐색하거나 자동 실행하지 않는다.
- [ ] v1에서 Intel Mac, Windows, system-wide multi-user daemon을 지원하지 않는다.

## 권장 구현 순서

1. Gateway/Monitor/Pet 계약 버전과 fixture를 additive하게 추가한다.
2. 단일 versioned runtime root와 resolver를 구현한다.
3. stage-validate-activate/rollback updater를 구현한다.
4. Swift runtime/transport abstraction과 first-run onboarding을 연결한다.
5. Pet state/action projection을 공통 모듈로 이동하고 renderer를 분리한다.
6. DMG signed/notarized release pipeline과 깨끗한 Mac acceptance를 완료한다.
