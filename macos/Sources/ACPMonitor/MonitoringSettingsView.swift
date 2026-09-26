import SwiftUI

/// Settings tab for the live monitoring hooks AgenLynk registers in Claude
/// Code, Codex and Grok. The sidecar installs them on start; this is where the
/// user sees what is registered and turns a CLI's hook off (or back on).
struct MonitoringSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

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
                historyRows
            }
        }
        .padding(20)
        .task {
            await model.loadHookStatus()
            await model.loadHistoryStats()
        }
        .alert("모니터 기록을 지금 삭제할까요?", isPresented: $confirmClear) {
            Button("기록 삭제", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("진행 중인 세션을 제외한 모든 지난 세션과 이벤트가 디스크와 대시보드에서 지워집니다. 되돌릴 수 없습니다.")
        }
    }

    @ViewBuilder
    private var historyRows: some View {
        if let stats = model.historyStats {
            if stats.diskHistoryOff {
                Label("보관 기간이 0이라 디스크에 기록을 남기지 않습니다. 앱을 다시 시작하면 지난 세션이 사라집니다.", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if stats.available {
                LabeledContent("크기", value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes ?? 0), countStyle: .file))
                LabeledContent("세션", value: "\((stats.sessions ?? 0).formatted())개 · 이벤트 \((stats.events ?? 0).formatted())개")
                if let retention = stats.retentionText {
                    LabeledContent("보관 기간", value: retention)
                }
                if let path = stats.path {
                    Text(path).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            } else {
                Label("기록 데이터베이스를 열 수 없습니다.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if model.historyStatsError == nil {
            ProgressView().controlSize(.small)
        }
        if let error = model.historyStatsError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        Text("보관 기간은 설정 > Gateway 구성 > 로컬 모니터링의 ‘모니터 기록 보관 기간’에서 바꿉니다. 0이면 디스크에 기록하지 않습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Button("기록 지금 삭제", role: .destructive) { confirmClear = true }
                .disabled(model.historyClearing || model.historyStats?.available != true)
            if model.historyClearing { ProgressView().controlSize(.small) }
            if let deleted = model.historyStats?.deleted {
                Text("세션 \(deleted.formatted())개 삭제됨").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ target: MonitoringHookTarget) -> some View {
        let label = Self.labels[target.provider] ?? target.provider
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // A partial registration shows as mixed: one source on, one
                // off. Only the first source's setter acts, so a click is one
                // install/uninstall.
                Toggle(label, sources: toggleSources(target), isOn: \.self)
                .disabled(!target.agentPresent || model.hookMutatingProvider != nil || target.error != nil)
                Spacer()
                if model.hookMutatingProvider == target.provider {
                    ProgressView().controlSize(.small)
                }
                Text(model.hookStatus?.stateText(for: target) ?? "")
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

    private func toggleSources(_ target: MonitoringHookTarget) -> [Binding<Bool>] {
        let act = Binding<Bool>(
            get: { target.installed || target.partial },
            set: { enabled in Task { await model.setHook(target.provider, enabled: enabled) } }
        )
        guard target.partial, !target.installed else { return [act] }
        return [act, Binding(get: { false }, set: { _ in })]
    }

    private func stateColor(_ target: MonitoringHookTarget) -> Color {
        if target.error != nil { return .red }
        if target.needsTrust || target.partial { return .orange }
        return target.installed ? .green : .secondary
    }
}
