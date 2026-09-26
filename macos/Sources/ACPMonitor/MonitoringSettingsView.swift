import SwiftUI

/// Settings tab for the live monitoring hooks AgenLynk registers in Claude
/// Code, Codex and Grok. The sidecar installs them on start; this is where the
/// user sees what is registered and turns a CLI's hook off (or back on).
struct MonitoringSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private static let labels = ["claude": "Claude Code", "codex": "Codex", "grok": "Grok"]

    var body: some View {
        Form {
            ACPLogoLockup(subtitle: "실시간 모니터링")
            Section {
                Label("각 CLI의 hook으로 도구 실행·권한 대기·턴 종료를 즉시 받아 봅니다. hook은 관찰만 하며 에이전트의 동작을 바꾸거나 막지 않습니다. 끄면 transcript 감지로 계속 동작하지만 권한 대기는 Codex에서만 보입니다.", systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("CLI별 hook") {
                if let status = model.hookStatus {
                    ForEach(status.targets) { target in
                        row(target)
                    }
                    if !status.receiving {
                        Label("현재 sidecar는 hook을 받지 않습니다. 앱을 다시 시작하세요.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if model.hookError == nil {
                    ProgressView().controlSize(.small)
                }
                if let error = model.hookError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section("기록") {
                Label("세션과 이벤트는 ~/.acp-gateway/agenlynk/monitor.db에 14일간 보관되어 앱을 다시 시작해도 최근 기록이 남습니다.", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .task { await model.loadHookStatus() }
    }

    @ViewBuilder
    private func row(_ target: MonitoringHookTarget) -> some View {
        let label = Self.labels[target.provider] ?? target.provider
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(label, isOn: Binding(
                    get: { target.installed || target.partial },
                    set: { enabled in Task { await model.setHook(target.provider, enabled: enabled) } }
                ))
                .disabled(!target.agentPresent || model.hookMutatingProvider != nil || target.error != nil)
                Spacer()
                if model.hookMutatingProvider == target.provider {
                    ProgressView().controlSize(.small)
                }
                Text(stateText(target))
                    .font(.caption)
                    .foregroundStyle(stateColor(target))
            }
            if target.needsTrust {
                Text("Codex에서 /hooks를 열어 AgenLynk hook을 승인해야 실행됩니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = target.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func stateText(_ target: MonitoringHookTarget) -> String {
        if !target.agentPresent { return "설치된 CLI 없음" }
        if target.error != nil { return "설정 파일 오류" }
        if target.needsTrust { return "승인 필요" }
        if target.installed { return "연결됨" }
        if target.partial { return "일부만 등록됨" }
        return target.disabled ? "꺼짐" : "등록 안 됨"
    }

    private func stateColor(_ target: MonitoringHookTarget) -> Color {
        if target.error != nil { return .red }
        if target.needsTrust || target.partial { return .orange }
        return target.installed ? .green : .secondary
    }
}
