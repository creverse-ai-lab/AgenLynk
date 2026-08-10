# ACP Gateway / Lynk v1 TODO

검토 기준: 2026-08-10 `dev`, Gateway `1.3.1` (`npm test` 213 pass, `npm run macos:test` pass, `npm run macos:verify` pass)

이 문서는 현재 코드와 테스트로 확인된 상태만 완료로 표시한다.

- `[x]`는 구현과 자동 테스트 또는 실제 산출물 검증 증거가 있다는 뜻이다.
- `[ ]`는 코드 일부나 지원 스크립트가 있어도 release acceptance가 끝나지 않았다는 뜻이다.
- notarization 같은 배포 항목은 “스크립트 지원”과 “실제 서명 산출물 통과”를 분리한다.

## v1 제품 목표

Lynk DMG를 설치한 라이트 사용자가 터미널이나 별도 Node 설치 없이 ACP Gateway를 시작하고, 모든 안전한 Gateway 설정과 에이전트 연결을 Swift UI에서 관리한다. 세션과 Frontdoor/Worker 연결 관계는 재시작 후에도 남아야 하며, 실시간 상태는 메뉴바 UI와 권한 없는 Pet renderer가 함께 소비한다.

```text
Lynk.app (SwiftUI + menu bar)
  -> versioned Monitor API (loopback HTTP/SSE)
  -> installed Gateway runtime/current
  -> Gateway daemon + ACP adapters

Monitor activity projection
  -> pet-state.json
  -> pet-actions.json
  -> bundled Pet 또는 사용자 renderer
```

## 현재 확보된 기반

- [x] Gateway `1.3.1` setup이 `gatewayApiVersion`, `gatewayVersion`, `gatewayBuildId`, `runtimeRoot`, `runtimeSource`, `capabilities`를 제공한다 (`src/gateway-service.js`, `src/version.js`).
- [x] Gateway seed를 `~/.acp-gateway/runtime/versions/<version>-<buildId>/`에 검증·설치하고 `current.json`을 원자적으로 교체한다 (`src/runtime-installer.js`).
- [x] 앱 번들 seed를 직접 실행하지 않고 설치된 runtime에서 daemon과 monitor를 실행한다 (`RuntimeProvisioner.swift`, `BundledRuntime.swift`, `SidecarController.swift`).
- [x] runtime manifest에 Gateway/API/Node 버전과 전체 payload SHA-256 inventory를 기록하고 seed와 설치본을 같은 코드로 검증한다 (`src/runtime-manifest.js`).
- [x] 기존 유효 runtime이 있으면 새 앱 seed가 이를 임의로 덮어쓰지 않는다 (`test/runtime-installer.test.js`).
- [x] 기존 `install.json`과 identity를 감지해 설치된 사용자는 onboarding을 건너뛴다 (`InstallStateChecker.swift`, `OnboardingLogicTests.swift`).
- [x] Gateway 세션, ACP session ID, 모델, opener agent와 최소 resume checkpoint를 저장하고 재시작 후 복원한다 (`src/gateway-service.js`, `test/gateway.test.js`).
- [x] Frontdoor/Worker topology, 이벤트, Task, Inbox와 세션 상세를 네이티브 SwiftUI에서 실시간 표시한다.
- [x] 안전하게 공개 가능한 Gateway runtime config 18개를 UI에서 조회·저장·초기화하고 안전 재시작한다 (`src/gateway-settings.js`, `SettingsView.swift`).
- [x] Gateway를 거치지 않는 로컬 Codex/Claude/Grok 세션과 그 sub-agent를 monitor 프로세스 안에서 직접 감지한다. 외부 스크립트도 `python3`/`sqlite3` CLI 의존도 없다 (`src/local-agents/`, `test/local-agents.test.js`).
- [x] `gatewayBuildId`가 `src/`와 `skills/` 전체를 재귀 해시해 중첩 payload 추가가 기존 설치에 반드시 도달하게 한다 (`src/version.js`, `test/runtime-manifest.test.js`).
- [x] 환경변수로 잠긴 config는 읽기 전용으로 표시하고 token/identity 같은 secret은 config 응답에 포함하지 않는다 (`test/gateway-settings.test.js`).
- [x] 공식 ACP agent catalog 조회, targeted install, On/Off와 adapter update 상태를 UI에서 관리한다.
- [x] 사용자 지정 renderer 실행 파일에 versioned `pet-state.json`/`pet-actions.json`을 atomic `0600`으로 전달하는 read-only 경계가 있다 (`PetController.swift`, `contracts/pet/v1/`).
- [x] Apple Silicon Node, Gateway seed, Swift 앱과 Applications 링크를 포함한 ad-hoc DMG를 생성·마운트 검증한다.
- [x] DMG checksum과 `Lynk.release.json`을 생성하고 runtime manifest, 코드서명, 번들 Node/npm/npx 실행을 검증한다.
- [x] 빠른 개발 suite와 전체 release suite를 분리하고 재생성 가능한 Swift/Node 파생 캐시 정리 명령을 제공한다.

## P0 — v1 출시 필수

### 1. DMG 서명과 실제 설치 acceptance

- [x] build script가 nested Node/helper 선서명, hardened runtime, Developer ID, `notarytool`, stapling 경로를 지원한다. 이는 capability 완료이며 실제 출시 게이트 G2는 충족하지 않는다.
- [x] ad-hoc `Lynk.dmg`를 read-only로 마운트해 앱, runtime payload, Applications 링크와 checksum을 검증했다.
- [ ] Lynk 앱 버전과 build number를 v1 release 값으로 확정한다.
- [ ] 실제 Developer ID Application identity로 앱과 DMG를 서명한다.
- [ ] notarization과 stapling을 통과한 `Lynk.release.json`에 `developer-id`, `notarized: true`, `stapled: true`를 기록한다.
- [ ] Gatekeeper가 활성화된 깨끗한 macOS 14 Apple Silicon에서 우회 실행 없이 앱을 연다.
- [ ] 시스템 Node와 기존 `~/.acp-gateway`가 없는 Mac에서 DMG 설치 → runtime 설치 → Frontdoor 선택 → Gateway health → Dashboard까지 완료한다.
- [ ] 실제 기존 CLI 설치가 있는 Mac에서 identity, provider 설정, session state와 MCP 등록을 보존하며 중복 Control MCP를 만들지 않는 수동 acceptance를 통과한다.

### 2. Config UI 완료 기준

- [x] lifecycle, resource limit, agent update의 안전한 runtime config 18개를 동적으로 렌더링한다.
- [x] 저장값, 기본값, 환경변수 잠금, 현재 적용값과 재시작 대기값을 구분한다.
- [x] 개별 초기화, 전체 초기화, 변경 저장과 안전 재시작을 제공한다.
- [x] 진행 중 session, Task 또는 미응답 Inbox가 있으면 Gateway 재시작을 차단한다.
- [x] 설정 변경이 `install.json`의 identity와 MCP 관리 정보를 보존하고 `0600`으로 원자 저장된다.
- [ ] Settings에 Lynk/Gateway/API/Node 버전, 설치 위치, current runtime과 update/repair/rollback 상태를 한 화면에 표시한다.
- [ ] 지원하지 않는 Gateway capability의 설정은 숨기거나 명확히 비활성화한다.

### 3. Monitor API v1과 메뉴바 UI

- [x] Swift UI가 인증된 loopback HTTP snapshot/SSE를 사용하고 Gateway socket RPC를 직접 호출하지 않는다 (`MonitorClient.swift`).
- [x] Dashboard, 메뉴바 popover, session detail window가 같은 실시간 snapshot을 사용한다.
- [x] `monitor_ready`와 `/api/meta`에 `monitorApiVersion`, Gateway identity, capabilities를 제공한다.
- [x] `/api/snapshot`과 모든 SSE envelope에 `schemaVersion`과 `monitorApiVersion`을 추가한다.
- [ ] 인증 실패, 미설치, API 비호환, 업데이트 필요, restart blocked를 안정된 error code로 구분한다. `monitor.js`에 `monitor_unauthorized`, `monitor_not_found`, `monitor_internal`, `monitor_restart_blocked`만 있고 미설치/API 비호환/업데이트 필요 코드가 없다.
- [x] Swift가 시작 handshake, snapshot과 SSE에서 지원하지 않는 schema/API major를 부분 decode하지 않고 업데이트 안내 오류로 전환한다.
- [x] `MenuBarExtra` 기반 메뉴바 진입점을 추가한다.
- [x] 메뉴바 클릭만으로 Gateway 상태, 활성 세션, 대기 요청, 최근 진행 상태를 작은 popover에서 확인한다.
- [x] popover에서 선택한 세션의 기존 상세 창을 열 수 있다.
- [x] popover가 실시간 세션 그래프를 좌→우 축약 형태로 직접 렌더링한다. 좌측은 프로젝트, 최신 노드 우측은 실행 중 모델을 표시하고 가로 스크롤로 과거 turn을 따라간다 (`MenuBarGraphView.swift`, `GraphProjection.lanesOrderedByTrunk`).
- [x] 중복이던 별도 Lynk Monitoring 창을 제거했다. 메뉴바 popover가 유일한 실시간 모니터링 표면이다.
- [x] 개별 창을 닫아도 Gateway daemon과 Worker는 유지하고 실제 앱 종료 시에만 앱이 소유한 sidecar/Pet을 종료한다.

### 4. 세션 기억과 연결 관계

- [x] Gateway session record와 ACP resume/load 정보를 재시작 후 복원한다.
- [x] 세션을 연 opener agent를 저장하고 Frontdoor 루트 아래 Worker topology로 투영한다.
- [x] 세션별 이벤트, 최종 답변, 모델, 상태와 pending input을 상세 UI에서 조회한다.
- [ ] Lynk 재실행 후 보존 기간 내 세션과 Frontdoor/Worker 관계가 같은 UI/Pet projection으로 복원되는 acceptance test를 추가한다.
- [ ] 앱 업데이트가 설치된 Gateway current runtime이나 기존 session state를 임의로 변경하지 않는지 검증한다.
- [x] 오래된 session이 retention 정책대로 정리되면서 active/pinned session은 보존된다. 시간(`sessionRetentionMs`, 기본 7일)과 개수(`artifactSessionLimit`, 기본 10) 두 조건이 함께 적용되고, 보존 기준을 낮출 때는 삭제 건수를 먼저 계산해 확인을 받는다 (`retentionPreview`, `test/gateway.test.js`).
- [ ] 위 정리 동작을 실제 UI에서 확인하는 acceptance를 추가한다. 현재 검증은 Gateway 단위 테스트와 `/api/retention-preview` 응답까지다.

### 5. Gateway 독립 업데이트와 롤백

- [x] versioned runtime, staging 검증과 원자적 `current.json` activation 기반이 있다.
- [x] 손상되거나 경로를 이탈한 current runtime을 거부하고 seed로 재설치할 수 있으며 symlink escape를 차단한다.
- [x] `inspect`, `stage`, `validate`, `activate`, `rollback`, `prune` 계약을 가진 updater를 정의한다 (`src/runtime-updater.js`, `test/runtime-updater.test.js`).
- [x] 활성화 전 manifest, checksum, runtime smoke test와 Gateway API 호환성을 검증한다 (`stage`가 변조 payload와 비호환 `gatewayApiVersion`을 거부하는 테스트).
- [x] previous known-good runtime을 기록하고 활성화 후 health mismatch 시 자동 롤백한다 (`activate atomically restores the previous target ...`).
- [x] session, Task, Inbox가 활성 상태면 updater가 activation/restart를 보류한다 (`activate and rollback both reject with a stable blocked error ...`).
- [ ] CLI와 Swift UI가 동일 updater 결과 JSON을 사용한다. CLI(`src/runtime-updater-cli.js`)는 단일 JSON envelope와 exit code를 보장하지만 Swift UI는 아직 updater를 호출하지 않는다.
- [x] 개발자용 `git pull` update(`src/source-update.js`)와 라이트 사용자용 runtime update(`src/runtime-updater.js`)를 별도 모듈로 분리한다.
- [ ] 기존 checkout 기반 CLI 설치를 versioned runtime으로 가져오는 idempotent migration과 dry-run을 제공한다.
- [ ] **전달 경로 주의**: `ensureRuntimeInstalled`는 유효한 current runtime이 있으면 앱 seed를 설치하지 않는다(의도된 안전장치). 따라서 런타임 변경은 updater를 통해서만 기존 설치에 도달하는데, Swift UI가 아직 updater를 호출하지 않으므로 **기존 사용자는 새 payload를 자동으로 받지 못한다.** 위 "CLI와 Swift UI가 동일 updater 결과 JSON을 사용한다" 항목이 이 문제의 해소 조건이다.

### 6. Pet / 사용자 renderer JSON 계약

- [x] prototype Pet이 Lynk가 만든 session/Inbox snapshot을 읽고 Frontdoor/Worker 관계를 표시한다.
- [x] `contracts/pet/v1/pet-state.schema.json`과 최소·전체 example을 추가한다.
- [x] `contracts/pet/v1/pet-actions.schema.json`과 최소·전체 example을 추가한다.
- [x] envelope를 `contract`, `version`, `generatedAt`, `producer`, `sequence`로 버전화한다.
- [x] agent state를 `offline`, `idle`, `starting`, `running`, `waiting`, `completed`, `failed`, `unknown`으로 정규화한다.
- [x] presentation action을 `sleep`, `wake`, `think`, `useTool`, `waitForUser`, `celebrate`, `error`, `disconnect`, `unknown`으로 고정한다.
- [x] Swift 상태 분류를 공통 activity projection으로 옮기고 `pet-state.json`과 `pet-actions.json`을 atomic `0600`으로 쓴다.
- [x] renderer 실행 계약을 명시적 executable path와 `PET_STATE_FILE`, `PET_ACTIONS_FILE` 중심의 최소 환경으로 제한한다.
- [x] renderer에 Monitor/Gateway token, 전체 prompt, agent cwd 같은 private data를 전달하지 않는다.
- [x] renderer가 만든 파일을 앱이 control 입력으로 읽지 않으며 Pet에서 Gateway mutation을 수행할 수 없게 한다.
- [x] 개발자 절대 Pet 프로젝트 경로 기본값을 제거한다.
- [x] 로컬 세션 감지를 외부 Python watcher에서 monitor 내장 Node 스캐너로 대체했다. 사용자 설정·`python3`·`sqlite3` CLI 의존이 모두 사라졌고, 별도 프로세스와 JSON 파일 IPC도 없다 (`src/local-agents/`).
- [x] 기본 Pet은 하나의 renderer일 뿐이며 사용자가 같은 JSON 계약으로 다른 UI를 연결할 수 있게 한다. 번들 `Contents/Helpers/LynkPet.app`이 기본값이고 `monitor.petExecutablePath`로 교체한다 (`AppSettings.BundledPet`, `PetController`).
- [ ] Pet 경계의 atomic `0600` 쓰기와 renderer 환경 제한에 Swift 자동 테스트를 추가한다. 현재 `PetControllerTests.swift`는 빈 경로 거부 한 건만 검사한다.

## P1 — v1 안정화와 유지보수

- [ ] Gateway setup, Monitor meta/snapshot/SSE의 JSON fixture를 만들고 Node와 Swift가 같은 fixture를 decode한다.
- [ ] 이전 minor, unknown additive field, 필수 필드 누락과 잘못된 major 호환성 테스트를 추가한다.
- [ ] socket을 점유한 daemon의 `runtimeRoot`와 current runtime을 비교해 split-brain spawn을 차단한다.
- [ ] runtime 경로 계산과 실행 entrypoint 선택을 공통 resolver로 모은다.
- [ ] `GatewayRuntimeManaging`과 `MonitorTransporting` 경계는 테스트 대역이나 호환성 처리에 필요한 최소 범위로만 도입한다.
- [x] 선택 가능한 번들 sample renderer를 제공한다. `verify-dmg.sh`가 번들 Pet의 `--self-test`와 코드서명을 release gate에서 검증한다.
- [ ] DMG seed가 앱 번들에서 직접 실행되지 않는 packaging test를 자동 release gate에 추가한다.
- [x] 메뉴바 popover와 Pet이 동일 activity projection을 공유하고, 진행 상태 정렬은 뷰가 아닌 모델에서 테스트된다 (`PetActivityProjection.orderedByProgress`, `MonitorModelTests.swift`).
- [ ] Dashboard까지 같은 projection으로 정렬·분류하도록 통일한다.

## P2 — v1 이후 사용자 편의

- [ ] 작업이 완료되면 macOS 알림 또는 작은 popup으로 세션과 최종 답변 일부를 표시한다.
- [ ] popup에 마지막 작업 상태, 답변 원문 열기와 다음 행동 선택지를 제공한다.
- [ ] 알림에서 작업을 시작한 기존 Frontdoor 세션을 찾아 다시 열거나 후속 요청으로 연결한다.
- [ ] 답변 preview 길이, 민감정보 표시와 알림 사용 여부를 사용자 설정으로 제어한다.
- [ ] 원격 update channel, delta update나 background Gateway 자동 업데이트는 서명·rollback 기반이 안정된 이후 검토한다.

## Release gate

- [x] **G0 Core CI** — 2026-08-10 `dev` 작업본에서 `npm test` 213개와 `npm run macos:test`를 로컬 재실행해 통과했다.
- [x] **G1 Ad-hoc package** — 2026-08-10 생성한 `build/Lynk.release.json` 기준으로 `npm run macos:dmg`와 `npm run macos:verify`가 통과했고 checksum이 DMG와 일치한다.
- [ ] **G2 Signed release** — Developer ID, notarization, stapling과 Gatekeeper 실행이 실제 산출물에서 통과한다.
- [ ] **G3 Fresh install** — Node와 기존 Gateway가 없는 깨끗한 Mac에서 DMG만으로 onboarding과 live monitoring이 완료된다.
- [ ] **G4 Existing install** — migration/dry-run 구현과 실제 기존 CLI 설치 acceptance가 모두 통과하고 identity, MCP, provider와 session data가 보존된다.
- [x] **G5 Config safety** — 안전 config 18개의 list/set/reset, env lock과 active-work restart blocker가 자동 테스트를 통과한다.
- [ ] **G6 Monitor/menu bar** — versioned Monitor API와 메뉴바 popover가 재연결·비호환 상태를 포함해 동작한다.
- [ ] **G7 Pet boundary** — 제3자 renderer가 두 JSON 파일만으로 동작하고 secret/control 권한을 얻지 못한다.
- [x] **G8 Update/rollback** — bad stage는 current를 바꾸지 않고 post-activation health 실패는 previous로 복구한다. 2026-08-10 `test/runtime-updater.test.js` 자동 테스트로 확인했다. Swift UI 연동과 기존 CLI migration은 남아 있다.

## v1 비범위

- 범용 plugin registry 또는 marketplace
- Pet에서 Gateway permission/config/restart/prompt 명령 전송
- 검증되지 않은 URL이나 로컬 임의 archive 설치
- 원격 자동 업데이트 서버, delta update, stable/beta channel
- Intel Mac, Windows, system-wide multi-user daemon
- 신뢰할 수 없는 renderer 자동 탐색·실행

## 권장 구현 순서

1. Monitor API v1 meta/schema/error 계약을 고정한다.
2. 메뉴바 popover를 기존 Dashboard/session detail에 연결한다.
3. Pet state/action JSON 계약과 공통 activity projection을 구현한다.
4. Gateway updater의 previous/rollback과 기존 CLI migration을 완성한다.
5. 1~4와 병행해 실제 Developer ID/notarization 산출물을 준비하고, 기능이 고정되면 fresh/existing Mac acceptance를 수행한다.
