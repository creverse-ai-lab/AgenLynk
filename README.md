# ACP Gateway

ACP Gateway는 하나의 Main 에이전트가 Claude, Grok, Codex Worker를 로컬에서 실행하고 관리할 수 있게 해주는 미들웨어입니다.

- ACP 세션과 provider 프로세스를 daemon이 계속 유지합니다.
- MCP가 재시작되어도 Worker 세션을 복구할 수 있습니다.
- 모델, 권한, 질문, 취소, 결과 수집을 Main이 통제합니다.
- Worker에는 Gateway 제어 권한을 전달하지 않습니다.
- 로컬 단일 사용자·단일 머신 사용을 기준으로 합니다.

Node.js 22 이상과 macOS 또는 Linux가 필요합니다.

## 구조

```text
사용자
  ↕
Main Agent
  ↕  Control MCP
ACP Gateway daemon
  ├─ Claude Worker
  ├─ Grok Worker
  └─ Codex Worker
```

Gateway daemon은 Unix socket, ACP 연결, 세션, 이벤트, permission 요청과 최소 복구 상태를 관리합니다. MCP는 Gateway에 명령을 전달하는 인터페이스입니다.

## 설치

```bash
cd ACP
npm install
npm link
acp-gateway-bootstrap --install-all
```

`--install-all`은 다음 작업을 수행합니다.

- 설치된 Claude·Grok·Codex 탐지
- 필요한 ACP adapter 설치
- Main 전용 `agent-acp` Control MCP 등록
- 읽기 전용 `agent-acp-guide` 등록
- Main에 `agent-delegator` skill 설치
- daemon 실행과 인증 상태 확인

기본 설치에서는 Codex를 Main으로 우선 선택합니다. Claude도 Main으로 사용하려면 다음과 같이 설치합니다.

```bash
acp-gateway-bootstrap --install-all --target all
```

설치 전에 변경 내용을 확인하려면:

```bash
acp-gateway-bootstrap --install-all --dry-run
```

주요 installer 옵션:

| 옵션 | 설명 |
|---|---|
| `--install-all` | Adapter, Control, Guide, skill 전체 설치 |
| `--install-control` | Main Control MCP만 설치 |
| `--install-guide` | 읽기 전용 Guide MCP만 설치 |
| `--install-skill` | `agent-delegator` skill만 설치 |
| `--target codex\|claude\|all` | 설치 대상 선택 |
| `--dry-run` | 실제 변경 없이 계획만 출력 |
| `--rotate-token` | Control token과 Main ID 교체 |
| `--force` | installer가 관리하지 않던 같은 이름의 항목 교체 |

Control token과 Main ID는 `~/.acp-gateway/install.json`에 권한 `0600`으로 저장되며 반복 설치에서도 재사용됩니다.

## 사용 흐름

설치된 `agent-delegator` skill을 사용하거나 Main이 다음 순서로 MCP 도구를 호출합니다.

1. `agent_acp_setup`으로 provider 확인
2. `agent_acp_session_open`으로 Worker 세션 생성
3. `agent_acp_prompt`로 작업 전달
4. `agent_acp_poll`로 이벤트와 상태 확인
5. 필요한 경우 `agent_acp_permission` 또는 `agent_acp_answer`로 응답
6. 완료 후 세션을 재사용하거나 `agent_acp_session`으로 종료

중간 poll에서는 `includeResult: false`를 사용하면 누적 결과의 반복 전송을 줄일 수 있습니다. 최종 상태에서만 `includeResult: true`로 전체 결과를 받으면 됩니다.

## 권한 정책

세션을 열 때 다음 정책 중 하나를 선택합니다.

| 정책 | 용도 |
|---|---|
| `read_only` | 분석, 검토, 읽기 전용 작업 |
| `ask` | 파일 변경이나 명령 실행 전에 Main 승인 필요 |
| `auto_approve` | 사용자가 허용한 세션 경계 안에서 자동 승인 |

Control token, Main ID와 Gateway socket 경로는 ACP Worker 환경에서 제거됩니다. Worker 세션에 Control MCP를 다시 주입하는 것도 차단합니다.

## 세션과 데이터

- 기본 상태 파일: `~/.acp-gateway/state.json`
- idle resumable 세션은 기본 30분 후 unload
- 결과와 이벤트는 기본 24시간 보존
- session resume checkpoint는 기본 7일 보존
- 장시간 유지가 필요한 세션은 `pin` 사용
- 응답 본문, thought, 전체 이벤트 이력은 상태 파일에 영구 저장하지 않음

## 주요 환경변수

| 변수 | 설명 |
|---|---|
| `ACP_GATEWAY_SOCKET` | Gateway Unix socket 경로 |
| `ACP_GATEWAY_STATE` | session checkpoint 파일 경로 |
| `ACP_GATEWAY_INSTALL_STATE` | installer 상태 파일 경로 |
| `ACP_GATEWAY_MAX_EVENTS` | 세션별 최근 이벤트 수 |
| `ACP_GATEWAY_MAX_TEXT_BYTES` | 세션별 결과·thought 최대 크기 |
| `CLAUDE_CODE_EXECUTABLE` | Claude Code 실행 경로 |
| `CODEX_ACP_BIN` | Codex ACP adapter 경로 |
| `GROK_BIN` | Grok 실행 경로 |

## 개발 및 테스트

```bash
npm test
npm run smoke
npm run smoke:subagents
```

- `npm test`: mock ACP 기반 전체 회귀 테스트
- `npm run smoke`: 실제 Claude·Grok 연결 테스트
- `npm run smoke:subagents`: 각 provider의 built-in child subagent 호출 테스트

현재 자동화 테스트는 55개입니다. 상세 시나리오는 [test_scinario.md](./test_scinario.md)를 참고하세요.
