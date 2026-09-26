import AppKit
import SwiftUI

/// Settings tab for the live monitoring hooks AgenLynk registers in Claude
/// Code, Codex and Grok. The sidecar installs them on start; this is where the
/// user sees what is registered and turns a CLI's hook off (or back on).
struct MonitoringSettingsView: View {
    @EnvironmentObject private var model: AppModel
    /// Opens Gateway 구성 at the monitor group, where retention is edited.
    var onEditRetention: () -> Void = {}
    @State private var confirmClear = false
    @State private var consentSheetPresented = false
    /// The CLI whose hook the user switched off, awaiting confirmation.
    @State private var pendingHookRemoval: String?

    private static let pollInterval: UInt64 = 15_000_000_000
    private static let retentionIds = ["localSessionRetentionMs", "monitorHistoryRetentionMs"]

    var body: some View {
        Form {
            ACPLogoLockup(subtitle: "실시간 모니터링")
            Section {
                Label("각 CLI의 hook으로 도구 실행·권한 대기·턴 종료를 즉시 받아 봅니다. hook은 관찰만 하며 에이전트의 동작을 바꾸거나 막지 않습니다. 끄면 대화 기록 파일로 계속 감지하지만 권한 대기는 Codex에서만 보입니다.", systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showsConsentButton {
                    Button("실시간 모니터링 켜기…") { consentSheetPresented = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section {
                if let status = model.hookStatus {
                    // Relative times ("1분 전") keep moving while the tab is open.
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(status.targets) { target in
                                row(target, status: status, now: context.date)
                            }
                        }
                    }
                    if !status.receiving {
                        Label("현재 모니터는 hook을 받지 않습니다. 앱을 다시 시작하세요.", systemImage: "exclamationmark.triangle")
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
            } header: {
                HStack {
                    Text("CLI별 hook")
                    Spacer()
                    Button("hook 상태 새로고침", systemImage: "arrow.clockwise") {
                        Task { await model.loadHookStatus() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("hook 상태를 다시 확인합니다")
                    .accessibilityLabel("hook 상태를 다시 확인합니다")
                }
            }
            Section("로컬 세션 감지") {
                Label("ACP를 통하지 않고 직접 실행한 Codex·Claude Code·Grok 세션과 그 하위 에이전트를 자동으로 감지해 로컬 세션으로 표시합니다. 모니터에 내장되어 있어 별도 설치가 필요하지 않습니다. hook을 켜면 같은 세션의 상태가 더 빨리 반영됩니다.", systemImage: "rectangle.stack.badge.person.crop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("기록") {
                historyRows
            }
        }
        .padding(20)
        .task {
            await model.loadHistoryStats()
            if model.gatewayConfigOptions.isEmpty { await model.loadGatewayConfig() }
            // "마지막 수신" is only as fresh as the last read: poll while the
            // tab is visible (the task ends when it is not).
            while !Task.isCancelled {
                await model.loadHookStatus()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
        .sheet(isPresented: $consentSheetPresented) {
            MonitoringConsentSheet()
        }
        .alert(
            "\(pendingHookRemoval.map(cliProductName) ?? "") hook을 제거할까요?",
            isPresented: Binding(get: { pendingHookRemoval != nil }, set: { if !$0 { pendingHookRemoval = nil } }),
            presenting: pendingHookRemoval
        ) { provider in
            Button("취소", role: .cancel) { pendingHookRemoval = nil }
            Button("hook 제거", role: .destructive) {
                pendingHookRemoval = nil
                Task { await model.setHook(provider, enabled: false) }
            }
        } message: { _ in
            Text("다음 업데이트에서 자동으로 켜지지 않습니다. 대화 기록 감지는 계속됩니다.")
        }
        .alert("모니터 기록을 지금 삭제할까요?", isPresented: $confirmClear) {
            Button("기록 삭제", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(model.historyStats?.available == true
                 ? "진행 중인 세션을 제외한 모든 지난 세션과 이벤트가 디스크와 대시보드에서 지워집니다. 되돌릴 수 없습니다."
                 : "디스크 기록이 꺼져 있어 남아 있는 기록 파일을 지웁니다. 되돌릴 수 없습니다.")
        }
    }

    /// Offered while the hooks were never agreed to, or nothing is on.
    private var showsConsentButton: Bool {
        guard let status = model.hookStatus, status.receiving else { return false }
        if status.consentRequired { return true }
        let present = status.targets.filter(\.agentPresent)
        return !present.isEmpty && present.allSatisfy { !$0.installed && !$0.partial }
    }

    @ViewBuilder
    private var historyRows: some View {
        ForEach(retentionOptions) { option in
            LabeledContent(option.labelKo, value: retentionValueText(option))
        }
        Button("보관 기간 바꾸기…") { onEditRetention() }
            .help("Gateway 구성 > 로컬 모니터링에서 대기 세션 유지 시간과 모니터 기록 보관 기간을 바꿉니다")
        if let stats = model.historyStats {
            if stats.diskHistoryOff {
                Label("보관 기간이 0이라 디스크에 기록을 남기지 않습니다. 앱을 다시 시작하면 지난 세션이 사라집니다.", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if stats.path != nil {
                    LabeledContent("남아 있는 기록 파일", value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes ?? 0), countStyle: .file))
                }
            } else if stats.available {
                LabeledContent("크기", value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes ?? 0), countStyle: .file))
                LabeledContent("세션", value: "\((stats.sessions ?? 0).formatted())개 · 이벤트 \((stats.events ?? 0).formatted())개")
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
        HStack {
            Button("기록 지금 삭제", role: .destructive) { confirmClear = true }
                .disabled(model.historyClearing || !canClearHistory)
            if model.historyClearing { ProgressView().controlSize(.small) }
            if let deleted = model.historyStats?.deleted {
                Text("세션 \(deleted.formatted())개 삭제됨").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Clearing works with disk history off too, as long as a file is left.
    private var canClearHistory: Bool {
        guard let stats = model.historyStats else { return false }
        return stats.available || stats.path != nil
    }

    private var retentionOptions: [GatewayConfigOption] {
        Self.retentionIds.compactMap { id in model.gatewayConfigOptions.first { $0.id == id } }
    }

    private func retentionValueText(_ option: GatewayConfigOption) -> String {
        guard let value = option.configuredValue.intValue else { return "—" }
        if value == 0 { return option.id == "monitorHistoryRetentionMs" ? "디스크에 남기지 않음" : "보관 안 함" }
        let scale = option.valueScale(for: value)
        let suffix = scale.suffix == "ms" ? "밀리초" : scale.suffix
        return scale.isScaled ? "\(scale.display(value))\(suffix)" : "\(value) \(suffix)"
    }

    @ViewBuilder
    private func row(_ target: MonitoringHookTarget, status: MonitoringHookStatus, now: Date) -> some View {
        let label = cliProductName(target.provider)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // A partial registration shows as mixed: one source on, one
                // off. Only the first source's setter acts, so a click is one
                // install/uninstall.
                Toggle(label, sources: toggleSources(target), isOn: \.self)
                    .disabled(!target.agentPresent || model.hookMutatingProvider != nil || target.error != nil)
                    .accessibilityLabel("\(label) hook")
                Spacer()
                if model.hookMutatingProvider == target.provider {
                    ProgressView().controlSize(.small)
                }
                Text(Self.stateText(for: target, in: status, now: now))
                    .font(.caption)
                    .foregroundStyle(stateColor(target))
            }
            if target.needsTrust {
                Text("Codex에서 /hooks를 열어 AgenLynk hook을 승인해야 실행됩니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = target.error {
                Text("설정 파일을 읽을 수 없어 건드리지 않았습니다. 파일을 고친 뒤 다시 확인하세요.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(error)
                HStack {
                    Button("파일 열기") { openConfigFile(target.file) }
                        .disabled(target.file.isEmpty)
                    Button("다시 확인") { Task { await model.loadHookStatus() } }
                }
                .controlSize(.small)
            }
        }
    }

    /// The settings row's state text for one CLI. Tells "the user turned this
    /// off" (kept across updates) apart from "never turned on".
    static func stateText(for target: MonitoringHookTarget, in status: MonitoringHookStatus, now: Date = Date()) -> String {
        if !target.agentPresent { return "설치된 CLI 없음" }
        if target.error != nil { return "설정 파일 오류" }
        if target.needsTrust { return "승인 필요" }
        if target.installed {
            guard let last = status.lastReceivedAt[target.provider] else { return "등록됨 · 아직 수신 없음" }
            return "등록됨 · 마지막 수신 \(relativeTimeText(from: last, to: now))"
        }
        if target.partial { return "일부만 등록됨" }
        if target.disabled { return "꺼짐 · 업데이트 후에도 유지" }
        return "아직 켜지 않음"
    }

    private func openConfigFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        // Reveal it in Finder when no app is set to open .json files.
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func toggleSources(_ target: MonitoringHookTarget) -> [Binding<Bool>] {
        let act = Binding<Bool>(
            get: { target.installed || target.partial },
            set: { enabled in
                // Removing edits the CLI's config file: ask first.
                if enabled {
                    Task { await model.setHook(target.provider, enabled: true) }
                } else {
                    pendingHookRemoval = target.provider
                }
            }
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
