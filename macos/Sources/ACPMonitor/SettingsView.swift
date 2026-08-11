import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            Form {
                ACPLogoLockup(subtitle: "표시 설정")
                Section("기본 표시") {
                    Toggle("활성 세션만 표시", isOn: $settings.activeOnly)
                }
                Section("이벤트") {
                    Toggle("AI thought 표시", isOn: $settings.showThoughts)
                    Toggle("Tool call 표시", isOn: $settings.showToolEvents)
                }
                Section("고급 연결") {
                    TextField("Node 실행 파일 경로 (자동 탐색 시 비움)", text: $settings.nodePath)
                    LabeledContent("Gateway", value: model.connectionDetail)
                    Button("Observer 다시 연결") { model.reconnect() }
                }
                Button("기본값으로 재설정") { model.resetSettings() }
            }
            .padding(20)
            .tabItem { Label("화면", systemImage: "slider.horizontal.3") }

            GatewayConfigurationView()
                .tabItem { Label("Gateway 구성", systemImage: "server.rack") }

            AgentCatalogView()
                .tabItem { Label("ACP 연결", systemImage: "cable.connector") }

            petConfiguration
                .tabItem { Label("Pet", systemImage: "pawprint") }

            RuntimeUpdateView()
                .tabItem { Label("버전·업데이트", systemImage: "arrow.down.circle") }

        }
        .frame(width: 780, height: 640)
        .task { await model.ensureStarted() }
    }

    private var petConfiguration: some View {
        Form {
            ACPLogoLockup(subtitle: "Agent status pet")
            Section("Renderer") {
                Toggle("Agent status pet 사용", isOn: Binding(
                    get: { settings.petEnabled },
                    set: { model.setPetEnabled($0) }
                ))
                LabeledContent("현재 renderer", value: settings.usesBundledPet ? "Lynk 기본 Pet" : "사용자 지정")
                TextField("사용자 renderer 경로 (비우면 기본 Pet)", text: $settings.petExecutablePath)
                    .disabled(model.petRunning)
                LabeledContent("상태", value: model.petStatus)
                if let error = model.petError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Button(model.petRunning ? "Pet 다시 시작" : "Pet 시작") {
                    model.restartPet()
                }
                .disabled(settings.resolvedPetExecutablePath.isEmpty)
            }
            Section("로컬 세션 감지") {
                Label("ACP를 통하지 않고 직접 실행한 Codex·Claude·Grok 세션과 그 하위 sub-agent를 자동으로 감지해 LOCAL로 표시합니다. Monitor에 내장되어 있어 별도 설정이나 설치가 필요하지 않습니다.", systemImage: "rectangle.stack.badge.person.crop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("상태 공유") {
                Label("Lynk가 Gateway(ACP)와 로컬 세션을 하나의 상태로 요약해 pet-state.json/pet-actions.json에 기록하면, 지정한 실행 파일이 그 두 파일만 읽어 표시합니다.", systemImage: "dot.radiowaves.left.and.right")
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
    @State private var numberDrafts: [String: Int] = [:]
    @State private var booleanDrafts: [String: Bool] = [:]
    @State private var originalNumberValues: [String: Int] = [:]
    @State private var originalBooleanValues: [String: Bool] = [:]
    @State private var confirmRestart = false
    @State private var pendingDestructiveSave: DestructiveSave?

    private static let knownGroups = ["agentUpdates", "lifecycle", "resourceLimits", "monitor"]

    /// Settings whose lower values destroy stored history. Raising them is
    /// always safe, so only a decrease needs confirming.
    private static let destructiveIds = ["sessionRetentionMs", "artifactSessionLimit"]

    /// A save the user has to confirm because it deletes data, carrying the
    /// counts the Gateway reported for exactly these values.
    private struct DestructiveSave: Identifiable {
        let id = UUID()
        let preview: RetentionPreview
        let andRestart: Bool
    }

    /// Known groups render first in a fixed, familiar order; any group the
    /// Gateway advertises beyond those (future settings) is appended in a
    /// deterministic (sorted) order instead of being silently dropped.
    private var groups: [String] {
        let present = Set(model.gatewayConfigOptions.map(\.group))
        let unknown = present.subtracting(Self.knownGroups).sorted()
        return (Self.knownGroups + unknown).filter(present.contains)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ACPLogoLockup(subtitle: "Gateway 전체 runtime config")
                Spacer()
                Button("새로고침", systemImage: "arrow.clockwise") {
                    Task { await model.loadGatewayConfig() }
                }
                .disabled(model.gatewayConfigLoading || model.gatewayConfigSaving || model.gatewayRestarting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            if model.gatewayConfigLoading && model.gatewayConfigOptions.isEmpty {
                Spacer()
                ProgressView("Gateway 설정을 불러오는 중…")
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusPanel
                        ForEach(groups, id: \.self) { group in
                            configSection(group)
                        }
                        if let error = model.gatewayConfigError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                }
                Divider()
                actionBar
            }
        }
        .task {
            if model.gatewayConfigOptions.isEmpty { await model.loadGatewayConfig() }
            syncDrafts()
        }
        .onChange(of: model.gatewayConfigOptions) { _, _ in syncDrafts() }
        .alert("Gateway 설정 적용 및 재시작", isPresented: $confirmRestart) {
            Button("취소", role: .cancel) {}
            Button("저장 후 안전 재시작", role: .destructive) {
                Task { await saveAndRestart() }
            }
        } message: {
            Text("진행 중 세션·Task·미응답 Inbox가 있으면 서버가 재시작을 차단합니다. 유휴 세션 기록은 보존되고 Worker는 다음 요청에서 복원됩니다.")
        }
        .alert("기록이 삭제됩니다", isPresented: destructiveSavePresented, presenting: pendingDestructiveSave) { save in
            Button("취소", role: .cancel) { pendingDestructiveSave = nil }
            Button("삭제하고 저장", role: .destructive) {
                let andRestart = save.andRestart
                pendingDestructiveSave = nil
                Task { _ = await commitDrafts(andRestart: andRestart) }
            }
        } message: { save in
            Text("보존 기준을 줄이면 \(save.preview.summary)가 삭제됩니다. 고정(pinned)했거나 진행 중인 세션은 삭제되지 않습니다. 계속할까요?")
        }
    }

    private var statusPanel: some View {
        GroupBox {
            HStack(spacing: 18) {
                statusItem("전체", value: "\(model.gatewayConfigOptions.count)", color: .blue)
                statusItem("환경변수 잠금", value: "\(model.gatewayConfigLockedCount)", color: .secondary)
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
                        onReset: resettable(option) ? { Task { await resetOption(option.id) } } : nil,
                        resetDisabled: model.gatewayConfigSaving || model.gatewayRestarting
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

    private func resetOption(_ id: String) async {
        if await model.resetGatewayConfig(ids: [id]) { syncDrafts() }
    }

    private var actionBar: some View {
        HStack {
            Button("모두 기본값으로") {
                Task {
                    let ids = model.gatewayConfigOptions.filter(\.editable).map(\.id)
                    if await model.resetGatewayConfig(ids: ids) { syncDrafts() }
                }
            }
            .disabled(model.gatewayConfigSaving || model.gatewayRestarting)
            Spacer()
            if hasDraftChanges {
                Text("저장하지 않은 변경사항").font(.caption).foregroundStyle(.orange)
            } else if model.gatewayConfigPendingApply {
                Text("저장됨 · 적용 대기").font(.caption).foregroundStyle(.orange)
            }
            Button("변경 저장") { Task { await saveDrafts() } }
                .disabled(!hasDraftChanges || model.gatewayConfigSaving || model.gatewayRestarting)
            Button("적용 및 안전 재시작") { confirmRestart = true }
                .buttonStyle(.borderedProminent)
                .disabled((!hasDraftChanges && !model.gatewayConfigPendingApply) || model.gatewayConfigSaving || model.gatewayRestarting)
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

    private var destructiveSavePresented: Binding<Bool> {
        Binding(
            get: { pendingDestructiveSave != nil },
            set: { if !$0 { pendingDestructiveSave = nil } }
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

    private func saveDrafts(andRestart: Bool = false) async -> Bool {
        // Nothing to save can still mean something to do: the restart button is
        // enabled in the "저장됨 · 적용 대기" state, where drafts are empty and
        // the whole point of the click is the restart itself.
        guard !draftValues.isEmpty else {
            return andRestart ? await model.restartGateway() : true
        }
        let lowered = loweredRetentionValues
        if !lowered.isEmpty {
            // Ask the Gateway what these exact values would delete before
            // writing them. A failed preview must not be read as "nothing".
            guard let preview = await model.retentionPreview(
                sessionRetentionMs: lowered["sessionRetentionMs"],
                artifactSessionLimit: lowered["artifactSessionLimit"]
            ) else { return false }
            if !preview.isEmpty {
                pendingDestructiveSave = DestructiveSave(preview: preview, andRestart: andRestart)
                return false
            }
        }
        return await commitDrafts(andRestart: andRestart)
    }

    private func commitDrafts(andRestart: Bool) async -> Bool {
        let saved = await model.saveGatewayConfig(values: draftValues)
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
        case "agentUpdates": "Agent 업데이트"
        case "lifecycle": "Lifecycle"
        case "monitor": "로컬 모니터링"
        case "resourceLimits": "Resource Limits"
        default: group
        }
    }

    private func groupSymbol(_ group: String) -> String {
        switch group {
        case "agentUpdates": "arrow.triangle.2.circlepath"
        case "monitor": "gauge.with.dots.needle.67percent"
        case "lifecycle": "clock.arrow.circlepath"
        default: "memorychip"
        }
    }
}

private struct GatewayRuntimeConfigRow: View {
    let option: GatewayConfigOption
    @Binding var numberValue: Int
    @Binding var booleanValue: Bool
    let onReset: (() -> Void)?
    let resetDisabled: Bool

    /// The scale this row is currently edited in, decided by the Gateway's
    /// `displayUnit` and by whether the present value divides evenly into it.
    /// 604800000 ms means nothing to a reader; "7 일" does.
    private var scale: GatewayValueScale { option.valueScale(for: numberValue) }

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
                        Text(option.requiresRestart ? "재시작 대기" : "적용 대기")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(option.descriptionKo).font(.caption).foregroundStyle(.secondary)
                if option.description != option.descriptionKo {
                    Text(option.description).font(.caption2).foregroundStyle(.tertiary)
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
            }
        }
        .padding(.vertical, 9)
        .opacity(option.editable ? 1 : 0.72)
    }

    @ViewBuilder
    private var control: some View {
        switch option.type {
        case "boolean":
            Toggle("", isOn: $booleanValue)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!option.editable)
        case "number":
            TextField("값", value: scaledBinding, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 145)
                .disabled(!option.editable)
                .help(scale.isScaled ? "저장은 \(numberValue) ms로 이루어집니다" : "")
            Text(scale.suffix)
                .font(scale.isScaled ? .caption : .caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
        default:
            Text("지원되지 않는 설정 형식 (\(option.type))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourceBadge: some View {
        Text(option.source == "environment" ? "ENV" : option.source == "stored" ? "저장값" : "기본값")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
