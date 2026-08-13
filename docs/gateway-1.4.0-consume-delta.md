# Gateway 1.4.0 소비 계약 차이

기준: AgenLynk `252391f`의 내장 Gateway 1.3.2와 `agent_gateway` `a1fdb35`의 1.4.0 `main`.

## 결정

AgenLynk 0.4.0은 `agent_gateway`의 **실제 1.4.0 wire contract**에 맞춘다. AgenLynk fork에만 존재하는 app 전용 RPC나 setup 필드를 Gateway 1.4.0에 소급해 필수 계약으로 만들지 않는다.

다만 소비 가능한 release에는 아래 배포 계약이 필요하다. 이는 wire 의미 변경이 아니라 public packaging 경계다.

- `v1.4.0` tag와 commit SHA
- immutable darwin-arm64 runtime asset
- SHA-256(가능하면 provenance 포함)
- sidecar가 import할 public client entrypoint

이 조건이 1.4.0 tag 전에 충족되지 못하면 AgenLynk의 pin 대상은 임의의 1.4.0 `main` commit이 아니라 다음 정식 consumer release가 된다.

## 확인된 wire 차이

| 항목 | AgenLynk 내장 1.3.2 | `agent_gateway` 1.4.0 | 0.4.0 처리 |
| --- | --- | --- | --- |
| setup identity | `gatewayBuildId`, `runtimeRoot`, `runtimeSource` 포함 | 포함하지 않음 | sidecar/app의 pinned manifest에서 기대 identity를 관리하고, 없는 daemon identity를 정상으로 가장하지 않음 |
| setup capability | `capabilities.agentUpdates` | `stateSchemaVersion`, `responseProfiles` 및 기존 setup blocks | 1.4.0 golden setup shape를 fixture로 고정 |
| config RPC | AgenLynk daemon의 `gateway_config` | 없음 | app/sidecar 설정과 Gateway public 설정의 소유권을 분리; 1.4.0에 없는 RPC를 호출하지 않음 |
| error branch | 일부 message substring 비교 | stable `errorCode`/`ERROR_CODES` | public client가 전달한 code로만 분기 |
| subscription pressure | reconnect/truncation 중심 | `acceptsGaps`, `subscription_gap`, cursor rewind | public 1.4.0 client를 사용하고 sidecar에서 gap을 diagnostics/reconciliation 신호로 처리 |
| package boundary | repo 내부 상대 import | `private: true`, `exports` 없음 | public client entrypoint가 release gate |
| runtime release | AgenLynk 소스 복사 | tag/asset 아직 없음 | tag+asset+digest 전에는 pinned 전환 금지 |

## 구현 차단 조건

다음 중 하나라도 없으면 Phase 4(pinned runtime 전환)를 시작하지 않는다.

1. tag/commit/asset/digest가 한 세트로 확정됨
2. public client가 RPC error code와 subscription gap semantics를 보존함
3. sidecar가 Gateway runtime 밖에서 실행됨
4. app 전용 config/catalog/runtime update의 소유자가 문서와 코드에서 분명함
5. Phase 1의 legacy 1.3.2 setup fixture와 Phase 3의 1.4.0 setup golden fixture가 각각 소유 저장소의 characterization test를 통과함

## 검증 근거

- 1.4.0 setup golden keys: `../ACP/test/characterization.test.js`
- 1.4.0 stable errors: `../ACP/src/errors.js`
- 1.4.0 gap-aware client: `../ACP/src/socket-rpc.js`
- AgenLynk app 전용 config RPC: `src/gateway-daemon.js`, `src/monitor.js`
- AgenLynk setup identity 및 split annotation: `src/gateway-service.js`, `src/monitor.js`
