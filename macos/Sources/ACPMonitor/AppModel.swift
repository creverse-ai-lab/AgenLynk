import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionPhase: Equatable {
        case idle
        case starting
        case connected
        case degraded(String)
        case disconnected(String)
    }

    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var gateway: JSONValue?
    @Published private(set) var sessions: [GatewaySession] = []
    @Published private(set) var eventsBySession: [String: [MonitorEvent]] = [:]
    @Published private(set) var tasks: [MonitorRecord] = []
    @Published private(set) var inbox: [MonitorRecord] = []
    @Published var selectedSessionId: String?
    @Published var selectedEventId: String?
    @Published var lastNotice: String?
    @Published private(set) var sessionConfigOptions: [SessionConfigOption] = []
    @Published private(set) var configSessionId: String?
    @Published private(set) var configLoading = false
    @Published private(set) var configSavingId: String?
    @Published private(set) var configError: String?
    @Published private(set) var configUnavailableReason: String?
    @Published private(set) var gatewayConfigOptions: [GatewayConfigOption] = []
    @Published private(set) var gatewayConfigLoading = false
    @Published private(set) var gatewayConfigSaving = false
    @Published private(set) var gatewayRestarting = false
    @Published private(set) var gatewayConfigError: String?
    @Published private(set) var petRunning = false
    @Published private(set) var petError: String?

    let settings = AppSettings()
    private let sidecar = SidecarController()
    private let client = MonitorClient()
    private let pet = PetController()
    private var startTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var endpoint: MonitorEndpoint?
    private var gatewayConnected = false
    private var gatewayStreaming = false
    private var sidecarStreamConnected = false

    var gatewayVersion: String {
        gateway?.objectValue?.string("gatewayVersion") ?? "—"
    }

    var gatewayBuild: String {
        gateway?.objectValue?.string("gatewayBuildId") ?? "—"
    }

    var connectionDetail: String {
        switch phase {
        case .idle: "Sidecar 대기"
        case .starting: "Sidecar 시작 및 Gateway 인증 중"
        case .connected: "Observer와 실시간 이벤트 구독 정상"
        case let .degraded(message), let .disconnected(message): message
        }
    }

    var persistenceHealthy: Bool? {
        gateway?.objectValue?.object("persistence")?.bool("healthy")
    }

    var detectedProviderCount: Int {
        gateway?.objectValue?.array("detected")?.count ?? 0
    }

    var gatewayLifecycle: [(String, String)] {
        guard let values = gateway?.objectValue?.object("lifecycle") else { return [] }
        return [
            ("Idle unload", duration(values.int("idleUnloadMs"))),
            ("Orphan grace", duration(values.int("orphanGraceMs"))),
            ("Result retention", duration(values.int("resultRetentionMs"))),
            ("Session retention", duration(values.int("sessionRetentionMs")))
        ]
    }

    var gatewayResourceLimits: [(String, String)] {
        guard let values = gateway?.objectValue?.object("resourceLimits") else { return [] }
        return [
            ("세션당 이벤트", formatted(values.int("maxEvents"))),
            ("텍스트 bytes", formatted(values.int("maxTextBytes"))),
            ("세션당 Terminal", formatted(values.int("maxTerminalsPerSession"))),
            ("대기 요청", formatted(values.int("maxPendingRequestsPerSession")))
        ]
    }

    var gatewayConfigPendingRestart: Bool { gatewayConfigOptions.contains { $0.pending && $0.requiresRestart } }
    var gatewayConfigPendingApply: Bool { gatewayConfigOptions.contains { $0.pending } }
    var gatewayConfigLockedCount: Int { gatewayConfigOptions.filter { !$0.editable }.count }

    var activeSessions: [GatewaySession] { sessions.filter(\.isActive) }
    var pendingInbox: [MonitorRecord] { inbox.filter { $0.status == "pending" || $0.status == "interrupted" } }
    var totalEventCount: Int { eventsBySession.values.reduce(0) { $0 + $1.count } }

    var petStatus: String {
        if petRunning { return "실행 중 · ACP 실시간 상태 공유" }
        if let petError { return petError }
        return "꺼짐"
    }

    var visibleSessions: [GatewaySession] {
        sessions
            .filter { !settings.activeOnly || $0.isActive }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    var allVisibleEvents: [MonitorEvent] {
        eventsBySession.values.flatMap { $0 }
            .filter(eventIsVisible)
            .sorted(by: eventSort)
    }

    var visibleEventsBySession: [String: [MonitorEvent]] {
        eventsBySession.mapValues { $0.filter(eventIsVisible) }
    }

    var selectedEvents: [MonitorEvent] {
        guard let selectedSessionId else { return allVisibleEvents }
        return (eventsBySession[selectedSessionId] ?? []).filter(eventIsVisible).sorted(by: eventSort)
    }

    var selectedEvent: MonitorEvent? {
        guard let selectedEventId else { return nil }
        return allVisibleEvents.first { $0.id == selectedEventId }
    }

    func startIfNeeded() {
        if settings.petEnabled && !petRunning { startPet() }
        guard startTask == nil else { return }
        startTask = Task { [weak self] in await self?.connect() }
    }

    func ensureStarted() async {
        startIfNeeded()
        await startTask?.value
    }

    func reconnect() {
        startTask?.cancel()
        reconciliationTask?.cancel()
        startTask = Task { [weak self] in await self?.connect(restartSidecar: true) }
    }

    func stop() {
        startTask?.cancel()
        reconciliationTask?.cancel()
        startTask = nil
        reconciliationTask = nil
        endpoint = nil
        sidecarStreamConnected = false
        gatewayConnected = false
        gatewayStreaming = false
        Task { await client.stop() }
        sidecar.stop()
        pet.stop()
        petRunning = false
    }

    func setPetEnabled(_ enabled: Bool) {
        settings.petEnabled = enabled
        if enabled {
            startPet()
        } else {
            pet.stop()
            petRunning = false
            petError = nil
        }
    }

    func restartPet() {
        settings.petEnabled = true
        startPet()
    }

    func resetSettings() {
        settings.reset()
        pet.stop()
        petRunning = false
        petError = nil
    }

    func loadSessionConfig(sessionId: String) async {
        guard let endpoint else {
            configError = "Gateway monitor가 아직 연결되지 않았습니다."
            return
        }
        configLoading = true
        configError = nil
        configUnavailableReason = nil
        do {
            let response = try await client.fetchSessionConfig(endpoint: endpoint, sessionId: sessionId)
            guard !Task.isCancelled else { return }
            configSessionId = response.sessionId
            sessionConfigOptions = response.options
            configUnavailableReason = response.unavailableReason
        } catch {
            configSessionId = sessionId
            sessionConfigOptions = []
            configUnavailableReason = nil
            configError = error.localizedDescription
        }
        configLoading = false
    }

    @discardableResult
    func setSessionConfig(sessionId: String, configId: String, value: JSONValue) async -> Bool {
        guard let endpoint else {
            configError = "Gateway monitor가 아직 연결되지 않았습니다."
            return false
        }
        configSavingId = configId
        configError = nil
        configUnavailableReason = nil
        do {
            let response = try await client.setSessionConfig(
                endpoint: endpoint,
                sessionId: sessionId,
                configId: configId,
                value: value
            )
            configSessionId = response.sessionId
            sessionConfigOptions = response.options
            configUnavailableReason = response.unavailableReason
            configSavingId = nil
            return true
        } catch {
            configError = error.localizedDescription
            configSavingId = nil
            return false
        }
    }

    func loadGatewayConfig() async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else {
            gatewayConfigError = "Gateway monitor가 아직 연결되지 않았습니다."
            return
        }
        gatewayConfigLoading = true
        gatewayConfigError = nil
        do {
            let snapshot = try await client.fetchGatewayConfig(endpoint: endpoint)
            gatewayConfigOptions = snapshot.options
        } catch {
            gatewayConfigError = error.localizedDescription
        }
        gatewayConfigLoading = false
    }

    @discardableResult
    func saveGatewayConfig(values: [String: JSONValue]) async -> Bool {
        guard let endpoint else {
            gatewayConfigError = "Gateway monitor가 아직 연결되지 않았습니다."
            return false
        }
        gatewayConfigSaving = true
        gatewayConfigError = nil
        do {
            let snapshot = try await client.saveGatewayConfig(endpoint: endpoint, values: values)
            gatewayConfigOptions = snapshot.options
            gatewayConfigSaving = false
            return true
        } catch {
            gatewayConfigError = error.localizedDescription
            gatewayConfigSaving = false
            return false
        }
    }

    func resetGatewayConfig(ids: [String]) async -> Bool {
        guard let endpoint else {
            gatewayConfigError = "Gateway monitor가 아직 연결되지 않았습니다."
            return false
        }
        gatewayConfigSaving = true
        gatewayConfigError = nil
        do {
            let snapshot = try await client.resetGatewayConfig(endpoint: endpoint, ids: ids)
            gatewayConfigOptions = snapshot.options
            gatewayConfigSaving = false
            return true
        } catch {
            gatewayConfigError = error.localizedDescription
            gatewayConfigSaving = false
            return false
        }
    }

    func restartGateway() async -> Bool {
        guard let endpoint else {
            gatewayConfigError = "Gateway monitor가 아직 연결되지 않았습니다."
            return false
        }
        gatewayRestarting = true
        gatewayConfigError = nil
        phase = .starting
        do {
            try await client.restartGateway(endpoint: endpoint)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await loadGatewayConfig()
            gatewayRestarting = false
            return true
        } catch {
            gatewayConfigError = error.localizedDescription
            gatewayRestarting = false
            updateConnectionPhase()
            return false
        }
    }

    private func connect(restartSidecar: Bool = false) async {
        phase = .starting
        reconciliationTask?.cancel()
        reconciliationTask = nil
        if restartSidecar { sidecar.stop() }
        do {
            let endpoint = try await sidecar.start(nodeOverride: settings.nodePath)
            self.endpoint = endpoint
            sidecarStreamConnected = false
            let snapshot = try await client.fetchSnapshot(endpoint: endpoint)
            apply(snapshot)
            await loadGatewayConfig()
            await client.startStream(endpoint: endpoint, onMessage: { [weak self] value in
                self?.apply(streamMessage: value)
            }, onState: { [weak self] connected, error in
                guard let self else { return }
                self.sidecarStreamConnected = connected
                if !connected {
                    self.phase = .disconnected(error ?? "Dashboard 데이터 스트림이 끊겼습니다.")
                } else {
                    self.updateConnectionPhase()
                }
            })
            startReconciliation(endpoint: endpoint)
        } catch {
            gatewayConnected = false
            gatewayStreaming = false
            sidecarStreamConnected = false
            phase = .disconnected(error.localizedDescription)
        }
    }

    private func startReconciliation(endpoint: MonitorEndpoint) {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.endpoint?.baseURL == endpoint.baseURL else { return }
                do {
                    let snapshot = try await self.client.fetchSnapshot(endpoint: endpoint)
                    guard !Task.isCancelled else { return }
                    self.apply(snapshot)
                    self.updateConnectionPhase()
                } catch {
                    // SSE의 재연결 상태가 사용자에게 노출된다. Snapshot 보정 실패는
                    // 다음 주기에 다시 시도해 일시적인 경합으로 Live를 끊지 않는다.
                }
            }
        }
    }

    private func apply(_ snapshot: MonitorSnapshot) {
        gateway = snapshot.gateway
        sessions = snapshot.sessions
        eventsBySession = snapshot.eventsBySession
        tasks = snapshot.tasks
        inbox = snapshot.inbox
        gatewayConnected = snapshot.connected
        gatewayStreaming = snapshot.streaming
        if !snapshot.connected { phase = .disconnected(snapshot.error ?? "Gateway에 연결되지 않았습니다.") }
        reconcileSelections()
        syncPetSnapshot()
    }

    private func apply(streamMessage value: JSONValue) {
        guard let message = value.objectValue, let kind = message.string("kind") else { return }
        switch kind {
        case "event":
            if let eventValue = message["event"], let event = MonitorEvent(eventValue) { append(event) }
        case "state":
            if let values = message.array("sessions") {
                sessions = values.compactMap(GatewaySession.init)
                let validSessionIds = Set(sessions.map(\.sessionId))
                eventsBySession = eventsBySession.filter { validSessionIds.contains($0.key) }
            }
            for sessionId in (message.array("removedSessionIds") ?? []).compactMap(\.stringValue) {
                eventsBySession.removeValue(forKey: sessionId)
                if selectedSessionId == sessionId { selectedSessionId = nil }
            }
            if let values = message.array("tasks") {
                tasks = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "task", index: $0.offset) }
            }
            if let values = message.array("inbox") {
                inbox = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "inbox", index: $0.offset) }
            }
            if let connected = message.bool("connected") { gatewayConnected = connected }
            if let streaming = message.bool("streaming") { gatewayStreaming = streaming }
            if gatewayConnected { updateConnectionPhase() }
            else { phase = .disconnected(message.string("error") ?? "Gateway 연결 끊김") }
            reconcileSelections()
            syncPetSnapshot()
        case "gateway":
            gateway = message["gateway"]
            Task { await loadGatewayConfig() }
        case "notice":
            lastNotice = message["event"]?.objectValue?.string("error") ?? "일부 이벤트를 다시 불러오지 못했습니다."
        case "session_removed":
            guard let sessionId = message.string("sessionId") else { break }
            removeSession(sessionId)
            syncPetSnapshot()
        default:
            break
        }
    }

    private func updateConnectionPhase() {
        guard sidecarStreamConnected else { return }
        if gatewayConnected && gatewayStreaming {
            phase = .connected
        } else if gatewayConnected {
            phase = .degraded("Gateway 조회 가능 · 실시간 이벤트 재연결 중")
        } else {
            phase = .disconnected("Gateway에 연결되지 않았습니다.")
        }
    }

    private func append(_ event: MonitorEvent) {
        var events = eventsBySession[event.sessionId] ?? []
        if let sequence = event.sequence, events.contains(where: { $0.sequence == sequence }) { return }
        events.append(event)
        if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
        eventsBySession[event.sessionId] = events
        if settings.followLatestEvent, selectedSessionId == nil || selectedSessionId == event.sessionId {
            selectedEventId = event.id
        }
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        eventsBySession.removeValue(forKey: sessionId)
        reconcileSelections()
    }

    private func startPet() {
        do {
            try pet.start(
                projectPath: settings.petProjectPath,
                snapshot: PetSnapshot.make(sessions: sessions, inbox: inbox)
            ) { [weak self] status in
                guard let self else { return }
                self.petRunning = false
                if self.settings.petEnabled {
                    self.petError = "Pet이 종료되었습니다 (exit \(status))."
                }
            }
            petRunning = true
            petError = nil
        } catch {
            petRunning = false
            petError = error.localizedDescription
        }
    }

    private func syncPetSnapshot() {
        guard settings.petEnabled, petRunning else { return }
        do {
            try pet.update(PetSnapshot.make(sessions: sessions, inbox: inbox))
            if petRunning { petError = nil }
        } catch {
            petError = "Pet 상태 공유 실패: \(error.localizedDescription)"
        }
    }

    private func reconcileSelections() {
        if let selectedSessionId, !sessions.contains(where: { $0.sessionId == selectedSessionId }) {
            self.selectedSessionId = activeSessions.first?.sessionId ?? sessions.first?.sessionId
        } else if selectedSessionId == nil {
            selectedSessionId = activeSessions.first?.sessionId ?? sessions.first?.sessionId
        }
        if let selectedEventId,
           !eventsBySession.values.joined().contains(where: { $0.id == selectedEventId }) {
            self.selectedEventId = nil
        }
    }

    private func eventIsVisible(_ event: MonitorEvent) -> Bool {
        if !settings.showThoughts, event.type == "agent_thought_chunk" { return false }
        if !settings.showToolEvents, event.type.hasPrefix("tool_call") { return false }
        return true
    }

    private func eventSort(_ lhs: MonitorEvent, _ rhs: MonitorEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return (lhs.timestamp ?? "") < (rhs.timestamp ?? "") }
        return (lhs.sequence ?? 0) < (rhs.sequence ?? 0)
    }

    private func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        let seconds = milliseconds / 1_000
        if seconds >= 86_400 { return "\(seconds / 86_400)일" }
        if seconds >= 3_600 { return "\(seconds / 3_600)시간" }
        if seconds >= 60 { return "\(seconds / 60)분" }
        return "\(seconds)초"
    }

    private func formatted(_ value: Int?) -> String { value?.formatted() ?? "—" }
}
