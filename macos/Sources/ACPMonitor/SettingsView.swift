import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var targetSessionId = ""

    private var configurableSessions: [GatewaySession] {
        model.sessions.filter { $0.status != "closed" }
    }

    private var targetSession: GatewaySession? {
        configurableSessions.first { $0.sessionId == targetSessionId }
    }

    var body: some View {
        TabView {
            Form {
                ACPLogoLockup(subtitle: "표시 설정")
                Section("기본 표시") {
                    Picker("Live Graph 시간 범위", selection: $settings.graphWindowMinutes) {
                        Text("최근 5분").tag(5)
                        Text("최근 15분").tag(15)
                        Text("최근 60분").tag(60)
                    }
                    Toggle("활성 세션만 표시", isOn: $settings.activeOnly)
                    Toggle("새 이벤트 자동 따라가기", isOn: $settings.followLatestEvent)
                }
                Section("이벤트") {
                    Toggle("AI thought 표시", isOn: $settings.showThoughts)
                    Toggle("Tool call 표시", isOn: $settings.showToolEvents)
                }
                Button("기본값으로 재설정") { model.resetSettings() }
            }
            .padding(20)
            .tabItem { Label("화면", systemImage: "slider.horizontal.3") }

            GatewayConfigurationView()
                .tabItem { Label("Gateway 구성", systemImage: "server.rack") }

            sessionConfiguration
                .tabItem { Label("Worker 구성", systemImage: "gearshape.2") }

            petConfiguration
                .tabItem { Label("Pet", systemImage: "pawprint") }

            Form {
                Section("Observer sidecar") {
                    TextField("Node 실행 파일 경로 (자동 탐색 시 비움)", text: $settings.nodePath)
                    LabeledContent("Gateway version", value: model.gatewayVersion)
                    LabeledContent("Gateway build", value: model.gatewayBuild)
                    LabeledContent("연결", value: model.connectionDetail)
                    Button("Observer 다시 연결") { model.reconnect() }
                }
                Section("보안 경계") {
                    Label("Control identity와 socket/state 경로는 이 화면에 노출하지 않습니다.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .tabItem { Label("연결", systemImage: "network") }
        }
        .frame(width: 780, height: 640)
        .task {
            await model.ensureStarted()
            if targetSessionId.isEmpty {
                targetSessionId = model.selectedSessionId ?? configurableSessions.first?.sessionId ?? ""
            }
        }
    }

    private var petConfiguration: some View {
        Form {
            ACPLogoLockup(subtitle: "Agent status pet")
            Section("Cursor overlay") {
                Toggle("Agent status pet 사용", isOn: Binding(
                    get: { settings.petEnabled },
                    set: { model.setPetEnabled($0) }
                ))
                TextField("Pet 프로젝트 경로", text: $settings.petProjectPath)
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
                .disabled(settings.petProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("상태 공유") {
                Label("ACP Monitor가 구독 중인 Gateway 세션과 Inbox 상태를 같은 snapshot으로 Pet에 전달합니다.", systemImage: "dot.radiowaves.left.and.right")
                Text("각 Worker를 연 최초 에이전트는 Frontdoor 루트로 합성되어 작업 트리의 시작점으로 함께 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("이 옵션으로 실행할 때는 pet의 별도 codex_app_watcher.py를 시작하지 않습니다. ACP 외부에서 직접 실행한 세션은 이 overlay에 포함되지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var sessionConfiguration: some View {
        Form {
            Section("Worker 세션") {
                Picker("세션", selection: $targetSessionId) {
                    if configurableSessions.isEmpty {
                        Text("사용 가능한 세션 없음").tag("")
                    }
                    ForEach(configurableSessions) { session in
                        Text("\(session.displayName) · \(session.provider)").tag(session.sessionId)
                    }
                }
                LabeledContent("상태", value: targetSession?.status ?? "—")
                LabeledContent("모델", value: targetSession?.model ?? "—")
                HStack {
                    Text("Worker가 ACP로 공개한 옵션만 표시합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("새로고침", systemImage: "arrow.clockwise") {
                        Task { await model.loadSessionConfig(sessionId: targetSessionId) }
                    }
                    .disabled(targetSessionId.isEmpty || model.configLoading)
                }
            }

            Section("수정 가능한 ACP config") {
                if model.configLoading {
                    ProgressView("설정을 불러오는 중…")
                } else if let error = model.configError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if model.sessionConfigOptions.isEmpty {
                    Text(model.configUnavailableReason ?? "이 세션의 Worker가 수정 가능한 config option을 공개하지 않았습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sessionConfigOptions) { option in
                        SessionConfigOptionRow(
                            option: option,
                            sessionId: targetSessionId,
                            disabled: targetSession?.isActive == true || model.configSavingId != nil
                        )
                    }
                }
                if targetSession?.isActive == true {
                    Label("작업 중인 세션은 완료된 뒤에 설정을 변경할 수 있습니다.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(20)
        .task(id: targetSessionId) {
            guard !targetSessionId.isEmpty else { return }
            await model.loadSessionConfig(sessionId: targetSessionId)
        }
    }
}

private struct GatewayConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var numberDrafts: [String: Int] = [:]
    @State private var booleanDrafts: [String: Bool] = [:]
    @State private var originalNumberValues: [String: Int] = [:]
    @State private var originalBooleanValues: [String: Bool] = [:]
    @State private var confirmRestart = false

    private let groups = ["agentUpdates", "lifecycle", "resourceLimits"]

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
                        booleanValue: booleanBinding(option)
                    )
                    if index < options.count - 1 { Divider().padding(.leading, 8) }
                }
            }
        } label: {
            Label(groupTitle(group), systemImage: groupSymbol(group)).font(.headline)
        }
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

    private func saveDrafts() async -> Bool {
        guard !draftValues.isEmpty else { return true }
        let saved = await model.saveGatewayConfig(values: draftValues)
        if saved { syncDrafts() }
        return saved
    }

    private func saveAndRestart() async {
        guard await saveDrafts() else { return }
        if await model.restartGateway() { syncDrafts() }
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
        case "resourceLimits": "Resource Limits"
        default: group
        }
    }

    private func groupSymbol(_ group: String) -> String {
        switch group {
        case "agentUpdates": "arrow.triangle.2.circlepath"
        case "lifecycle": "clock.arrow.circlepath"
        default: "memorychip"
        }
    }
}

private struct GatewayRuntimeConfigRow: View {
    let option: GatewayConfigOption
    @Binding var numberValue: Int
    @Binding var booleanValue: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.label).font(.callout.weight(.medium))
                    sourceBadge
                    if option.pending {
                        Text(option.requiresRestart ? "재시작 대기" : "적용 대기")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(option.description).font(.caption).foregroundStyle(.secondary)
                if !option.editable {
                    Text("\(option.environment)에서 고정됨")
                        .font(.caption2.monospaced()).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 16)
            if option.type == "boolean" {
                Toggle("", isOn: $booleanValue)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!option.editable)
            } else {
                TextField("값", value: $numberValue, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 145)
                    .disabled(!option.editable)
                Text(option.unit ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
            }
        }
        .padding(.vertical, 9)
        .opacity(option.editable ? 1 : 0.72)
    }

    private var sourceBadge: some View {
        Text(option.source == "environment" ? "ENV" : option.source == "stored" ? "저장값" : "기본값")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct SessionConfigOptionRow: View {
    @EnvironmentObject private var model: AppModel
    let option: SessionConfigOption
    let sessionId: String
    let disabled: Bool
    @State private var booleanValue: Bool

    init(option: SessionConfigOption, sessionId: String, disabled: Bool) {
        self.option = option
        self.sessionId = sessionId
        self.disabled = disabled
        _booleanValue = State(initialValue: option.currentValue.boolValue ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch option.type {
            case "select":
                Picker(option.name, selection: selectBinding) {
                    ForEach(option.choices) { choice in
                        Text(choice.name).tag(choice.value)
                    }
                }
            case "boolean":
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name)
                        if let category = option.category {
                            Text(category).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if model.configSavingId == option.id {
                        ProgressView().controlSize(.small)
                    }
                    Toggle("", isOn: booleanBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(booleanValue ? "켜짐" : "꺼짐")
                }
                .frame(maxWidth: .infinity)
            default:
                LabeledContent(option.name, value: option.currentValue.stringValue ?? "—")
            }
            if let description = option.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
            } else if let category = option.category, option.type != "boolean" {
                Text(category).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .disabled(disabled || !["select", "boolean"].contains(option.type))
        .opacity(model.configSavingId == option.id ? 0.55 : 1)
    }

    private var selectBinding: Binding<String> {
        Binding(
            get: { option.currentValue.stringValue ?? "" },
            set: { value in
                Task { await model.setSessionConfig(sessionId: sessionId, configId: option.id, value: .string(value)) }
            }
        )
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: { booleanValue },
            set: { value in
                let previous = booleanValue
                booleanValue = value
                Task {
                    let saved = await model.setSessionConfig(
                        sessionId: sessionId,
                        configId: option.id,
                        value: .bool(value)
                    )
                    if !saved { booleanValue = previous }
                }
            }
        )
    }
}
