import SwiftUI

/// Settings window tabs, so one tab can send the user to another.
enum SettingsTab: Hashable {
    case display, gateway, agents, monitoring, pet, updates
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var tab: SettingsTab = .display
    /// A Gateway 구성 group to scroll to when that tab opens.
    @State private var gatewayFocusGroup: String?
    @State private var confirmDisplayReset = false

    var body: some View {
        TabView(selection: $tab) {
            Form {
                ACPLogoLockup(subtitle: "표시 설정")
                Section("기본 표시") {
                    Toggle("활성 세션만 표시", isOn: $settings.activeOnly)
                }
                dashboardViewsSection
                Section("이벤트") {
                    Toggle("생각 표시", isOn: $settings.showThoughts)
                    Toggle("도구 호출 표시", isOn: $settings.showToolEvents)
                }
                Section("고급 연결") {
                    TextField("Node 실행 파일 경로 (자동 탐색 시 비움)", text: $settings.nodePath)
                    LabeledContent("Gateway", value: model.connectionDetail)
                    Button("모니터 다시 연결") { model.reconnect() }
                        .help("모니터에 다시 연결합니다. Gateway와 에이전트는 멈추지 않습니다.")
                }
                Button("기본값으로 재설정") { confirmDisplayReset = true }
            }
            .padding(20)
            .alert("표시, Node 경로, 펫 설정을 기본값으로 되돌릴까요?", isPresented: $confirmDisplayReset) {
                Button("취소", role: .cancel) {}
                Button("기본값으로 재설정", role: .destructive) { model.resetSettings() }
            } message: {
                Text("사용자 펫 경로는 지워집니다.")
            }
            .tabItem { Label("화면", systemImage: "slider.horizontal.3") }
            .tag(SettingsTab.display)

            GatewayConfigurationView(focusGroup: $gatewayFocusGroup)
                .tabItem { Label("Gateway 구성", systemImage: "server.rack") }
                .tag(SettingsTab.gateway)

            AgentCatalogView()
                .tabItem { Label("ACP 연결", systemImage: "cable.connector") }
                .tag(SettingsTab.agents)

            MonitoringSettingsView(onEditRetention: {
                gatewayFocusGroup = "monitor"
                tab = .gateway
            })
            .tabItem { Label("모니터링", systemImage: "bolt.horizontal.circle") }
            .tag(SettingsTab.monitoring)

            petConfiguration
                .tabItem { Label("펫", systemImage: "pawprint") }
                .tag(SettingsTab.pet)

            RuntimeUpdateView()
                .tabItem { Label("버전·업데이트", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)

        }
        .frame(width: 780, height: 640)
        .task { await model.ensureStarted() }
    }

    private var dashboardViewsSection: some View { DashboardViewsSection() }

    private var petConfiguration: some View {
        Form {
            ACPLogoLockup(subtitle: "에이전트 상태 펫")
            Section("렌더러") {
                Toggle("에이전트 상태 펫 사용", isOn: Binding(
                    get: { settings.petEnabled },
                    set: { model.setPetEnabled($0) }
                ))
                LabeledContent("현재 렌더러", value: settings.usesBundledPet ? "AgenLynk 기본 펫" : "사용자 지정")
                TextField("사용자 렌더러 경로 (비우면 기본 펫)", text: $settings.petExecutablePath)
                    .disabled(model.petRunning)
                LabeledContent("상태", value: model.petStatus)
                if let error = model.petError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Button(model.petRunning ? "펫 다시 시작" : "펫 시작") {
                    model.restartPet()
                }
                .disabled(settings.resolvedPetExecutablePath.isEmpty)
            }
            Section("상태 공유") {
                Label("AgenLynk가 Gateway(ACP)와 로컬 세션을 하나의 상태로 요약해 pet-state.json/pet-actions.json에 기록하면, 지정한 실행 파일이 그 두 파일만 읽어 표시합니다.", systemImage: "dot.radiowaves.left.and.right")
                Text("각 Worker를 연 최초 에이전트는 Frontdoor 루트로 합성되어 작업 트리의 시작점으로 함께 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

}

private struct GatewayConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var focusGroup: String?
    @State private var numberDrafts: [String: Int] = [:]
    @State private var booleanDrafts: [String: Bool] = [:]
    @State private var originalNumberValues: [String: Int] = [:]
    @State private var originalBooleanValues: [String: Bool] = [:]
    @State private var confirmRestart = false
    @State private var pendingConfirmation: DestructiveConfirmation?

    private static let knownGroups = ["agentUpdates", "lifecycle", "resourceLimits", "workers", "monitor"]

    /// Settings whose lower values destroy stored history. Raising them is
    /// always safe, so only a decrease needs confirming.
    private static let destructiveIds = ["sessionRetentionMs", "artifactSessionLimit", "monitorHistoryRetentionMs"]
    /// The ones the Gateway itself can count deletions for.
    private static let gatewayCountedIds: Set<String> = ["sessionRetentionMs", "artifactSessionLimit"]

    /// A change the user has to confirm because it may delete data.
    private struct DestructiveConfirmation: Identifiable {
        enum Action {
            case save(andRestart: Bool, deletesDiskHistory: Bool)
            case reset(ids: [String])
        }
        let id = UUID()
        var title = "기록이 삭제될 수 있습니다"
        let message: String
        let confirmTitle: String
        let action: Action
    }

    /// Known groups render first in a fixed, familiar order; any group the
    /// Gateway advertises beyond those (future settings) is appended in a
    /// deterministic (sorted) order instead of being silently dropped.
    private var groups: [String] {
        let present = Set(model.gatewayConfigOptions.map(\.group))
        let unknown = present.subtracting(Self.knownGroups).sorted()
        return (Self.knownGroups + unknown).filter(present.contains)
    }

    private var busy: Bool { model.gatewayConfigSaving || model.gatewayRestarting }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ACPLogoLockup(subtitle: "Gateway 전체 설정")
                Spacer()
                Button("새로고침", systemImage: "arrow.clockwise") {
                    Task { await model.loadGatewayConfig() }
                }
                .disabled(model.gatewayConfigLoading || busy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            if model.gatewayConfigLoading && model.gatewayConfigOptions.isEmpty {
                Spacer()
                ProgressView("Gateway 설정을 불러오는 중…")
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            statusPanel
                            ForEach(groups, id: \.self) { group in
                                configSection(group).id(group)
                            }
                            if let error = model.gatewayConfigError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(20)
                    }
                    .onAppear { scrollToFocus(proxy) }
                    .onChange(of: focusGroup) { _, _ in scrollToFocus(proxy) }
                    .onChange(of: model.gatewayConfigOptions.isEmpty) { _, _ in scrollToFocus(proxy) }
                }
                Divider()
                actionBar
            }
        }
        .task {
            if model.gatewayConfigOptions.isEmpty { await model.loadGatewayConfig() }
            syncDrafts()
            await model.loadHistoryStats()
        }
        .onChange(of: model.gatewayConfigOptions) { _, _ in syncDrafts() }
        .alert("Gateway 설정 적용 및 재시작", isPresented: $confirmRestart) {
            Button("취소", role: .cancel) {}
            Button("저장 후 안전 재시작", role: .destructive) {
                Task { await saveAndRestart() }
            }
        } message: {
            Text("진행 중 세션·태스크·미응답 요청이 있으면 서버가 재시작을 차단합니다. 대기 세션 기록은 보존되고 Worker는 다음 요청에서 복원됩니다.")
        }
        .alert(pendingConfirmation?.title ?? "", isPresented: confirmationPresented, presenting: pendingConfirmation) { confirmation in
            Button("취소", role: .cancel) { pendingConfirmation = nil }
            Button(confirmation.confirmTitle, role: .destructive) {
                pendingConfirmation = nil
                Task { await perform(confirmation.action) }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let group = focusGroup, groups.contains(group) else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(group, anchor: .top) }
            focusGroup = nil
        }
    }

    private var statusPanel: some View {
        GroupBox {
            HStack(spacing: 18) {
                statusItem("전체", value: "\(model.gatewayConfigOptions.count)", color: .blue)
                statusItem("환경 변수로 고정", value: "\(model.gatewayConfigLockedCount)", color: .secondary)
                statusItem("재시작 대기", value: "\(model.gatewayConfigOptions.filter(\.pending).count)", color: .orange)
                Spacer()
                if model.gatewayRestarting { ProgressView("Gateway 재시작 중…") }
            }
        } label: {
            Label("적용 상태", systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    private func statusItem(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func configSection(_ group: String) -> some View {
        let options = model.gatewayConfigOptions.filter { $0.group == group }
        return GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    GatewayRuntimeConfigRow(
                        option: option,
                        numberValue: numberBinding(option),
                        booleanValue: booleanBinding(option),
                        reconnectsMonitor: model.isMonitorConfigOption(option.id),
                        onReset: resettable(option) ? { Task { await requestReset(ids: [option.id]) } } : nil,
                        resetDisabled: busy
                    )
                    if index < options.count - 1 { Divider().padding(.leading, 8) }
                }
            }
        } label: {
            Label(groupTitle(group), systemImage: groupSymbol(group)).font(.headline)
        }
    }

    /// Only offer per-row reset when the setting is editable (not locked by
    /// an environment variable) and actually has a stored override to clear —
    /// resetting a value already at default would be a no-op.
    private func resettable(_ option: GatewayConfigOption) -> Bool {
        option.editable && option.storedValue != nil
    }

    private var actionBar: some View {
        HStack {
            Button("모두 기본값으로") {
                let ids = model.gatewayConfigOptions.filter(\.editable).map(\.id)
                Task { await requestReset(ids: ids, all: true) }
            }
            .disabled(busy)
            Spacer()
            if hasDraftChanges {
                Text("저장하지 않은 변경사항").font(.caption).foregroundStyle(.orange)
            } else if model.gatewayConfigPendingApply {
                Text("저장됨 · 적용 대기").font(.caption).foregroundStyle(.orange)
            }
            Button("변경 저장") { Task { await saveDrafts() } }
                .disabled(!hasDraftChanges || busy)
            Button("적용 및 안전 재시작") { confirmRestart = true }
                .buttonStyle(.borderedProminent)
                .disabled((!hasDraftChanges && !model.gatewayConfigPendingApply) || busy)
        }
        .padding(14)
    }

    private var draftValues: [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for option in model.gatewayConfigOptions where option.editable {
            if option.type == "boolean", let value = booleanDrafts[option.id] {
                if value != originalBooleanValues[option.id] { values[option.id] = .bool(value) }
            } else if option.type == "number", let value = numberDrafts[option.id] {
                if value != originalNumberValues[option.id] { values[option.id] = .number(Double(value)) }
            }
        }
        return values
    }

    private var hasDraftChanges: Bool { !draftValues.isEmpty }

    private func syncDrafts() {
        let numbers: [String: Int] = Dictionary(uniqueKeysWithValues: model.gatewayConfigOptions.compactMap { option -> (String, Int)? in
            guard let value = option.configuredValue.intValue else { return nil }
            return (option.id, value)
        })
        let booleans: [String: Bool] = Dictionary(uniqueKeysWithValues: model.gatewayConfigOptions.compactMap { option -> (String, Bool)? in
            guard let value = option.configuredValue.boolValue else { return nil }
            return (option.id, value)
        })
        numberDrafts = numbers
        booleanDrafts = booleans
        originalNumberValues = numbers
        originalBooleanValues = booleans
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    /// Values being lowered, among the settings that destroy history.
    private var loweredRetentionValues: [String: Int] {
        var lowered: [String: Int] = [:]
        for id in Self.destructiveIds {
            guard let next = numberDrafts[id], let current = originalNumberValues[id], next < current else { continue }
            lowered[id] = next
        }
        return lowered
    }

    /// A reset asks first when a default is lower than what is configured for
    /// a setting whose lower values delete data, and says what would go, the
    /// same way saving does. "모두 기본값으로" always asks.
    private func requestReset(ids: [String], all: Bool = false) async {
        var lowered: [String: Int] = [:]
        for id in ids where Self.destructiveIds.contains(id) {
            guard let option = model.gatewayConfigOptions.first(where: { $0.id == id }),
                  let current = option.configuredValue.intValue,
                  let fallback = option.defaultValue.intValue,
                  fallback < current else { continue }
            lowered[id] = fallback
        }
        let (messages, _) = await deletionMessages(lowered)
        guard !messages.isEmpty else {
            if all {
                pendingConfirmation = DestructiveConfirmation(
                    title: "모든 설정을 기본값으로 되돌릴까요?",
                    message: "저장된 값을 지우고 기본값을 사용합니다. 삭제되는 기록은 없습니다.",
                    confirmTitle: "기본값으로 되돌리기",
                    action: .reset(ids: ids)
                )
            } else {
                await perform(.reset(ids: ids))
            }
            return
        }
        pendingConfirmation = DestructiveConfirmation(
            message: ((all ? ["모든 설정을 기본값으로 되돌립니다."] : []) + messages).joined(separator: " "),
            confirmTitle: "삭제하고 기본값으로",
            action: .reset(ids: ids)
        )
    }

    /// What lowering these values would delete, as confirmation sentences
    /// ending in a question. Empty when nothing would be deleted.
    private func deletionMessages(_ lowered: [String: Int]) async -> (messages: [String], deletesDiskHistory: Bool) {
        var messages: [String] = []
        var deletesDiskHistory = false
        if !lowered.keys.filter(Self.gatewayCountedIds.contains).isEmpty {
            // Ask the Gateway what these exact values would delete. When it
            // cannot count, say so instead of reading that as "nothing".
            switch await model.retentionPreview(
                sessionRetentionMs: lowered["sessionRetentionMs"],
                artifactSessionLimit: lowered["artifactSessionLimit"]
            ) {
            case let .counted(preview) where !preview.isEmpty:
                messages.append("보존 기준을 줄이면 \(preview.summary)가 삭제됩니다. 고정했거나 진행 중인 세션은 삭제되지 않습니다.")
            case .counted:
                break
            case .uncounted:
                messages.append("보존 기준을 줄이면 오래된 세션 기록이 삭제됩니다. 삭제될 개수는 확인할 수 없습니다.")
            }
        }
        if let history = lowered["monitorHistoryRetentionMs"] {
            if history == 0 {
                deletesDiskHistory = true
                if let bytes = model.diskHistoryBytes {
                    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    messages.append("디스크 기록을 끄고 기존 기록(\(size))을 삭제할까요?")
                } else {
                    messages.append("디스크 기록을 끄고 기존 기록을 삭제할까요?")
                }
            } else {
                messages.append("모니터 기록 보관 기간을 줄이면 그보다 오래된 세션 기록이 디스크에서 삭제됩니다.")
            }
        }
        if !messages.isEmpty, !(messages.last?.hasSuffix("?") ?? false) { messages.append("계속할까요?") }
        return (messages, deletesDiskHistory)
    }

    private func perform(_ action: DestructiveConfirmation.Action) async {
        switch action {
        case let .save(andRestart, deletesDiskHistory):
            _ = await commitDrafts(andRestart: andRestart, deletesDiskHistory: deletesDiskHistory)
        case let .reset(ids):
            if await model.resetGatewayConfig(ids: ids) { syncDrafts() }
        }
    }

    private func saveDrafts(andRestart: Bool = false) async -> Bool {
        // Nothing to save can still mean something to do: the restart button is
        // enabled in the "저장됨 · 적용 대기" state, where drafts are empty and
        // the whole point of the click is the restart itself.
        guard !draftValues.isEmpty else {
            return andRestart ? await model.restartGateway() : true
        }
        let lowered = loweredRetentionValues
        guard !lowered.isEmpty else { return await commitDrafts(andRestart: andRestart, deletesDiskHistory: false) }
        let (messages, deletesDiskHistory) = await deletionMessages(lowered)
        guard !messages.isEmpty else { return await commitDrafts(andRestart: andRestart, deletesDiskHistory: false) }
        pendingConfirmation = DestructiveConfirmation(
            message: messages.joined(separator: " "),
            confirmTitle: "삭제하고 저장",
            action: .save(andRestart: andRestart, deletesDiskHistory: deletesDiskHistory)
        )
        return false
    }

    private func commitDrafts(andRestart: Bool, deletesDiskHistory: Bool) async -> Bool {
        // Marked before saving: saving retention 0 reconnects the monitor, and
        // the file is removed once the new monitor no longer has it open.
        if deletesDiskHistory { model.setDiskHistoryDeletionPending(true) }
        let saved = await model.saveGatewayConfig(values: draftValues)
        if !saved, deletesDiskHistory { model.setDiskHistoryDeletionPending(false) }
        if saved { syncDrafts() }
        guard saved, andRestart else { return saved }
        return await model.restartGateway()
    }

    private func saveAndRestart() async {
        // saveDrafts owns the restart when it commits, so a confirmation
        // prompt can carry the restart intent across the user's decision.
        _ = await saveDrafts(andRestart: true)
    }

    private func numberBinding(_ option: GatewayConfigOption) -> Binding<Int> {
        Binding(
            get: { numberDrafts[option.id] ?? option.configuredValue.intValue ?? option.minimum ?? 0 },
            set: { numberDrafts[option.id] = $0 }
        )
    }

    private func booleanBinding(_ option: GatewayConfigOption) -> Binding<Bool> {
        Binding(
            get: { booleanDrafts[option.id] ?? option.configuredValue.boolValue ?? false },
            set: { booleanDrafts[option.id] = $0 }
        )
    }

    private func groupTitle(_ group: String) -> String {
        switch group {
        case "agentUpdates": "에이전트 업데이트"
        case "lifecycle": "세션 수명"
        case "monitor": "로컬 모니터링"
        case "resourceLimits": "자원 제한"
        case "workers": "Worker 기록"
        default: group
        }
    }

    private func groupSymbol(_ group: String) -> String {
        switch group {
        case "agentUpdates": "arrow.triangle.2.circlepath"
        case "monitor": "gauge.with.dots.needle.67percent"
        case "lifecycle": "clock.arrow.circlepath"
        case "workers": "person.2"
        default: "memorychip"
        }
    }
}

private struct GatewayRuntimeConfigRow: View {
    let option: GatewayConfigOption
    @Binding var numberValue: Int
    @Binding var booleanValue: Bool
    /// Saving this one restarts the monitor rather than the Gateway.
    let reconnectsMonitor: Bool
    let onReset: (() -> Void)?
    let resetDisabled: Bool

    /// The scale this row is currently edited in, decided by the Gateway's
    /// `displayUnit` and by whether the present value divides evenly into it.
    /// 604800000 ms means nothing to a reader; "7 일" does. Sizes read the
    /// same way in KB or MB when they divide evenly.
    private var scale: GatewayValueScale {
        switch option.unit {
        case "bytes":
            let mebibyte = 1_048_576
            if numberValue > 0, numberValue % mebibyte == 0 { return GatewayValueScale(factor: mebibyte, suffix: "MB") }
            if numberValue > 0, numberValue % 1_024 == 0 { return GatewayValueScale(factor: 1_024, suffix: "KB") }
            return GatewayValueScale(factor: 1, suffix: "바이트")
        case "count":
            return GatewayValueScale(factor: 1, suffix: "개")
        default:
            return option.valueScale(for: numberValue)
        }
    }

    private var storedUnitText: String {
        switch option.unit {
        case "bytes": "바이트"
        case "ms": "밀리초"
        default: option.unit ?? ""
        }
    }

    /// The unit beside the field. History retention 0 means no disk history,
    /// not "0 일"; a raw millisecond value reads "밀리초".
    private var suffixText: String {
        if option.id == "monitorHistoryRetentionMs", numberValue == 0 { return "디스크에 남기지 않음" }
        return scale.suffix == "ms" ? "밀리초" : scale.suffix
    }

    /// Edits happen in display units and are converted straight back to stored
    /// milliseconds. The result is clamped to the Gateway's own minimum so a
    /// scaled editor can never submit a value the server would reject.
    private var scaledBinding: Binding<Int> {
        Binding(
            get: { scale.display(numberValue) },
            set: { numberValue = max(option.minimum ?? 0, scale.stored($0)) }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.labelKo).font(.callout.weight(.medium))
                    // English stays visible as the secondary line: the setting
                    // ids, environment variables, and docs are all English, so
                    // the Korean text must not be the only way to find them.
                    if option.label != option.labelKo {
                        Text(option.label).font(.caption).foregroundStyle(.secondary)
                    }
                    sourceBadge
                    if option.pending {
                        Text(reconnectsMonitor ? "모니터 다시 연결 대기" : option.requiresRestart ? "재시작 대기" : "적용 대기")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(option.descriptionKo).font(.caption).foregroundStyle(.secondary)
                if option.description != option.descriptionKo {
                    Text(option.description).font(.caption2).foregroundStyle(.tertiary)
                }
                if reconnectsMonitor {
                    Text("저장하면 모니터를 다시 연결합니다")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !option.editable {
                    Text("\(option.environment)에서 고정됨")
                        .font(.caption2.monospaced()).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 16)
            control
            if let onReset {
                Button("기본값으로 초기화", systemImage: "arrow.uturn.backward") { onReset() }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .disabled(resetDisabled)
                    .help("저장된 값을 지우고 기본값으로 되돌립니다")
                    .accessibilityLabel("저장된 값을 지우고 기본값으로 되돌립니다")
            }
        }
        .padding(.vertical, 9)
        .opacity(option.editable ? 1 : 0.72)
    }

    @ViewBuilder
    private var control: some View {
        switch option.type {
        case "boolean":
            Toggle(option.labelKo, isOn: $booleanValue)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!option.editable)
                .accessibilityLabel(option.labelKo)
        case "number":
            TextField(option.labelKo, value: scaledBinding, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 145)
                .disabled(!option.editable)
                .optionalHelp(scale.isScaled ? "저장 값: \(numberValue) \(storedUnitText)" : nil)
                .accessibilityLabel(option.labelKo)
            Text(suffixText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: 42, alignment: .leading)
        default:
            Text("지원되지 않는 설정 형식입니다")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourceBadge: some View {
        Text(option.source == "environment" ? "환경 변수" : option.source == "stored" ? "저장값" : "기본값")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

extension View {
    /// A tooltip only when there is something to say: an empty `.help("")`
    /// still registers a blank tooltip.
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// 화면 > 대시보드 보기: which center views the dashboard offers and which
/// one a launch opens on (docs/ux-policy.md §9).
private struct DashboardViewsSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section {
            ForEach(DashboardMode.allCases) { mode in
                let isLast = settings.enabledDashboardModes == [mode]
                Toggle(isOn: Binding(
                    get: { settings.isDashboardModeEnabled(mode) },
                    set: { settings.setDashboardMode(mode, enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mode.label)
                        Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(isLast)
                .help(isLast ? "보기를 하나 이상 켜 두어야 합니다" : "\(mode.label) 보기를 대시보드에 보이거나 숨깁니다")
            }
            Picker("처음 여는 보기", selection: Binding(
                get: { settings.defaultDashboardMode },
                set: { settings.setDefaultDashboardMode($0) }
            )) {
                ForEach(settings.enabledDashboardModes) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .help("앱을 실행하면 대시보드가 이 보기로 열립니다. 실행 중에 바꾼 보기는 앱을 끌 때까지 유지됩니다.")
        } header: {
            Text("대시보드 보기")
        } footer: {
            Text("대시보드 가운데에 보일 보기를 고릅니다. 하나만 켜면 전환 버튼이 사라집니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
