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

    enum StartupPhase: Equatable {
        case checking
        case provisioningRuntime
        case runtimeError(String)
        case onboarding
        case ready
    }

    @Published private(set) var startupPhase: StartupPhase = .checking
    @Published var onboardingFrontDoor: String = "codex"
    @Published private(set) var onboardingRunning = false
    @Published private(set) var onboardingOutput: [String] = []
    @Published private(set) var onboardingError: String?
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var gateway: JSONValue?
    @Published private(set) var sessions: [GatewaySession] = []
    @Published private(set) var eventsBySession: [String: [MonitorEvent]] = [:]
    @Published private(set) var historySessions: [GatewaySession] = []
    @Published private(set) var historyEventsBySession: [String: [MonitorEvent]] = [:]
    @Published private(set) var logSessions: [GatewaySession] = []
    @Published private(set) var logEventsBySession: [String: [MonitorEvent]] = [:]
    @Published private(set) var tasks: [MonitorRecord] = []
    @Published private(set) var inbox: [MonitorRecord] = []
    @Published var selectedFrontdoorId: String?
    @Published var selectedSessionId: String?
    @Published var selectedEventId: String?
    @Published var lastNotice: String?
    @Published private(set) var agentCatalog: [ACPAgentCatalogItem] = []
    @Published private(set) var agentCatalogLoading = false
    @Published private(set) var agentCatalogMutationId: String?
    @Published private(set) var agentCatalogSource = "—"
    @Published private(set) var agentCatalogStale = false
    @Published private(set) var agentCatalogError: String?
    @Published private(set) var gatewayConfigOptions: [GatewayConfigOption] = []
    @Published private(set) var gatewayConfigLoading = false
    @Published private(set) var gatewayConfigSaving = false
    @Published private(set) var gatewayRestarting = false
    @Published private(set) var gatewayConfigError: String?
    @Published private(set) var sessionConfigSessionId: String?
    @Published private(set) var sessionConfigOptions: [SessionConfigOption] = []
    @Published private(set) var sessionConfigLoading = false
    @Published private(set) var sessionConfigSaving = false
    @Published private(set) var sessionConfigError: String?
    @Published private(set) var sessionConfigUnavailableReason: String?
    @Published private(set) var petRunning = false
    @Published private(set) var petError: String?

    let settings = AppSettings()
    private let sidecar = SidecarController()
    private let client = MonitorClient()
    private let pet = PetController()
    private let installer = InstallerController()
    private let runtimeProvisioner = RuntimeProvisioner()
    private var startupCheckStarted = false
    private var startTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var streamFlushTask: Task<Void, Never>?
    private var pendingStreamEvents: [MonitorEvent] = []
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

    /// Wall-clock time of the last message received from the Monitor stream,
    /// regardless of kind. This is the liveness signal the menu bar shows: it
    /// keeps ticking while agents are idle, so "no active agent" and "no data
    /// arriving" stay distinguishable.
    @Published private(set) var lastStreamMessageAt: Date?
    /// Time of the last agent event, as opposed to a state/heartbeat message.
    @Published private(set) var lastAgentEventAt: Date?

    var streamingLive: Bool { gatewayConnected && gatewayStreaming }

    /// Every known Frontdoor and Worker with its normalized contract state.
    /// Uses the same `PetActivityProjection` the Pet renderer consumes, so the
    /// menu bar and the Pet can never disagree about an agent's state.
    var activityProjection: PetActivityProjection {
        PetActivityProjection.make(sessions: sessions.filter { !$0.isInternalReview }, inbox: inbox)
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
    var onboardingInstallLocationReady: Bool { BundledRuntime.installationLocationReady }

    var activeSessions: [GatewaySession] { sessions.filter(\.isActive) }
    var frontdoorSessions: [FrontdoorSession] {
        FrontdoorSession.make(sessions: sessions.filter { !$0.isInternalReview })
    }
    var activeFrontdoors: [FrontdoorSession] { frontdoorSessions.filter(\.isActive) }
    var realtimeSessions: [GatewaySession] {
        let liveCandidates = sessions.filter { !$0.isInternalReview }
        let activeFrontdoorIds = Set(liveCandidates.filter(\.isActive).compactMap(\.openerInstanceId))
        return liveCandidates
            .filter { session in
                session.isRealtimeVisible || (session.isFrontdoorRecord && activeFrontdoorIds.contains(session.openerInstanceId ?? ""))
            }
            .sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
    }
    var realtimeInbox: [MonitorRecord] {
        let sessionIds = Set(realtimeSessions.map(\.sessionId))
        return inbox.filter { record in
            guard let sessionId = record.payload.objectValue?.string("sessionId") else { return false }
            return sessionIds.contains(sessionId)
        }
    }
    var realtimeACPCount: Int { realtimeSessions.filter { !$0.isLocalSource }.count }
    var realtimeLocalCount: Int { realtimeSessions.filter(\.isLocalSource).count }
    var pendingInbox: [MonitorRecord] { inbox.filter { $0.status == "pending" || $0.status == "interrupted" } }
    var visibleLogSessions: [GatewaySession] { logSessions.filter { !$0.isInternalReview } }
    var logFrontdoorSessions: [FrontdoorSession] { FrontdoorSession.make(sessions: visibleLogSessions) }
    var totalEventCount: Int {
        let visibleIds = Set(visibleLogSessions.map(\.sessionId))
        return logEventsBySession.filter { visibleIds.contains($0.key) }.values.reduce(0) { $0 + $1.count }
    }

    var petStatus: String {
        if petRunning { return "실행 중 · ACP 실시간 상태 공유" }
        if let petError { return petError }
        return "꺼짐"
    }

    var visibleFrontdoors: [FrontdoorSession] {
        frontdoorSessions.filter { !settings.activeOnly || $0.isActive }
    }

    var selectedFrontdoor: FrontdoorSession? {
        guard let selectedFrontdoorId else { return nil }
        return frontdoorSessions.first { $0.id == selectedFrontdoorId }
    }

    var selectedSession: GatewaySession? {
        guard let selectedSessionId else { return nil }
        return visibleLogSessions.first { $0.sessionId == selectedSessionId }
    }

    var allVisibleEvents: [MonitorEvent] {
        let mappedSessionIds = Set(logFrontdoorSessions.flatMap { $0.members.map(\.sessionId) })
        return logEventsBySession
            .filter { mappedSessionIds.contains($0.key) }
            .values.flatMap { $0 }
            .filter(eventIsVisible)
            .sorted(by: eventSort)
    }

    var visibleEventsBySession: [String: [MonitorEvent]] {
        eventsBySession.mapValues { $0.filter(eventIsVisible) }
    }

    var selectedEvents: [MonitorEvent] {
        guard let selectedFrontdoorId,
              let frontdoor = logFrontdoorSessions.first(where: { $0.id == selectedFrontdoorId }) else {
            return allVisibleEvents
        }
        return frontdoor.members
            .flatMap { logEventsBySession[$0.sessionId] ?? [] }
            .filter(eventIsVisible)
            .sorted(by: eventSort)
    }

    var selectedEvent: MonitorEvent? {
        guard let selectedEventId else { return nil }
        return allVisibleEvents.first { $0.id == selectedEventId }
    }

    func startIfNeeded() {
        switch startupPhase {
        case .checking:
            guard !startupCheckStarted else { return }
            startupCheckStarted = true
            Task { [weak self] in await self?.performStartupCheck() }
        case .provisioningRuntime, .runtimeError, .onboarding:
            return
        case .ready:
            if settings.petEnabled && !petRunning { startPet() }
            guard startTask == nil else { return }
            startTask = Task { [weak self] in await self?.connect() }
        }
    }

    /// One-time startup sequence: install/activate the bundled runtime seed
    /// (no-op in source-tree development, see RuntimeProvisioner), then
    /// decide whether an existing Control identity lets us skip straight to
    /// the dashboard or first-run onboarding is needed.
    private func performStartupCheck() async {
        startupPhase = .provisioningRuntime
        do {
            _ = try await runtimeProvisioner.ensureInstalled()
        } catch {
            startupPhase = .runtimeError(error.localizedDescription)
            return
        }
        startupPhase = InstallStateChecker.isValid(at: InstallStateChecker.defaultPath()) ? .ready : .onboarding
        startIfNeeded()
    }

    /// Retries the runtime seed install after a failure (e.g. transient disk
    /// error); does nothing unless the app is currently showing that error.
    func retryRuntimeProvisioning() {
        guard case .runtimeError = startupPhase else { return }
        startupCheckStarted = false
        startupPhase = .checking
        startIfNeeded()
    }

    /// Runs the bundled bootstrap (--install-all --front-door <target>
    /// --refresh-registry) from the first-run onboarding surface. Monitoring
    /// only starts after the installer reports a health-verified success.
    func startOnboardingInstall() {
        guard !onboardingRunning, onboardingInstallLocationReady else { return }
        onboardingRunning = true
        onboardingError = nil
        onboardingOutput.removeAll()
        let frontDoor = onboardingFrontDoor
        let nodeOverride = settings.nodePath
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.installer.run(frontDoor: frontDoor, nodeOverride: nodeOverride) { line in
                    Task { @MainActor [weak self] in self?.appendOnboardingOutput(line) }
                }
                self.onboardingRunning = false
                if result.ok {
                    self.startupPhase = .ready
                    self.startIfNeeded()
                } else {
                    self.onboardingError = result.message
                }
            } catch {
                self.onboardingRunning = false
                self.onboardingError = error.localizedDescription
            }
        }
    }

    private func appendOnboardingOutput(_ line: String) {
        onboardingOutput.append(line)
        if onboardingOutput.count > 200 { onboardingOutput.removeFirst(onboardingOutput.count - 200) }
    }

    func ensureStarted() async {
        startIfNeeded()
        await startTask?.value
    }

    func reconnect() {
        startTask?.cancel()
        reconciliationTask?.cancel()
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingStreamEvents.removeAll(keepingCapacity: true)
        startTask = Task { [weak self] in await self?.connect(restartSidecar: true) }
    }

    func stop() {
        startTask?.cancel()
        reconciliationTask?.cancel()
        streamFlushTask?.cancel()
        startTask = nil
        reconciliationTask = nil
        streamFlushTask = nil
        pendingStreamEvents.removeAll(keepingCapacity: true)
        endpoint = nil
        sidecarStreamConnected = false
        gatewayConnected = false
        gatewayStreaming = false
        Task { await client.stop() }
        sidecar.stop()
        pet.stop()
        petRunning = false
        installer.cancel()
        runtimeProvisioner.cancel()
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

    func loadAgentCatalog(refresh: Bool = false) async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else {
            agentCatalogError = "Gateway monitor가 아직 연결되지 않았습니다."
            return
        }
        agentCatalogLoading = true
        agentCatalogError = nil
        do {
            apply(try await client.fetchAgentCatalog(endpoint: endpoint, refresh: refresh))
        } catch {
            agentCatalogError = error.localizedDescription
        }
        agentCatalogLoading = false
    }

    func installAgent(_ agent: ACPAgentCatalogItem) async {
        await mutateAgent(agent, body: [
            "action": .string("install"),
            "registryId": .string(agent.registryId)
        ])
    }

    func setAgentEnabled(_ agent: ACPAgentCatalogItem, enabled: Bool) async {
        await mutateAgent(agent, body: [
            "action": .string("set_enabled"),
            "providerId": .string(agent.providerId),
            "enabled": .bool(enabled)
        ])
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
    /// What the Gateway would delete if these retention values were applied.
    /// Returns nil when the Gateway cannot be asked, in which case the caller
    /// must not claim that nothing would be lost.
    func retentionPreview(sessionRetentionMs: Int?, artifactSessionLimit: Int?) async -> RetentionPreview? {
        guard let endpoint else { return nil }
        do {
            return try await client.retentionPreview(
                endpoint: endpoint,
                sessionRetentionMs: sessionRetentionMs,
                artifactSessionLimit: artifactSessionLimit
            )
        } catch {
            gatewayConfigError = error.localizedDescription
            return nil
        }
    }

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

    /// Loads the Worker-advertised config options for one session (ACP
    /// `session/config` via `/api/session-config`). There is no reset/default
    /// action in ACP for these — only whatever the Worker currently reports.
    func loadSessionConfig(sessionId: String) async {
        sessionConfigSessionId = sessionId
        sessionConfigOptions = []
        sessionConfigLoading = true
        sessionConfigSaving = false
        sessionConfigError = nil
        sessionConfigUnavailableReason = nil
        if endpoint == nil { await ensureStarted() }
        guard !Task.isCancelled, sessionConfigSessionId == sessionId else { return }
        guard let endpoint else {
            sessionConfigError = "Gateway monitor가 아직 연결되지 않았습니다."
            sessionConfigLoading = false
            return
        }
        do {
            let snapshot = try await client.fetchSessionConfig(endpoint: endpoint, sessionId: sessionId)
            guard !Task.isCancelled, sessionConfigSessionId == sessionId else { return }
            sessionConfigOptions = snapshot.options
            sessionConfigUnavailableReason = snapshot.unavailableReason
        } catch is CancellationError {
            return
        } catch {
            guard sessionConfigSessionId == sessionId else { return }
            sessionConfigError = error.localizedDescription
        }
        if sessionConfigSessionId == sessionId { sessionConfigLoading = false }
    }

    @discardableResult
    func setSessionConfig(sessionId: String, configId: String, value: JSONValue) async -> Bool {
        guard sessionConfigSessionId == sessionId, !sessionConfigLoading, !sessionConfigSaving else { return false }
        guard let endpoint else {
            sessionConfigError = "Gateway monitor가 아직 연결되지 않았습니다."
            return false
        }
        sessionConfigSaving = true
        sessionConfigError = nil
        do {
            let snapshot = try await client.setSessionConfig(endpoint: endpoint, sessionId: sessionId, configId: configId, value: value)
            guard !Task.isCancelled, sessionConfigSessionId == sessionId else { return false }
            sessionConfigOptions = snapshot.options
            sessionConfigUnavailableReason = snapshot.unavailableReason
            sessionConfigSaving = false
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard sessionConfigSessionId == sessionId else { return false }
            sessionConfigError = error.localizedDescription
            sessionConfigSaving = false
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
            // Authenticated compatibility handshake before any normal
            // snapshot/stream consumption; throws a stable update-required
            // error if the Monitor's schema/API major isn't supported.
            _ = try await client.fetchMeta(endpoint: endpoint)
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
                try? await Task.sleep(nanoseconds: 10_000_000_000)
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
        lastStreamMessageAt = Date()
        var logCacheChanged = false
        if gateway != snapshot.gateway { gateway = snapshot.gateway }
        if sessions != snapshot.sessions { sessions = snapshot.sessions; logCacheChanged = true }
        if eventsBySession != snapshot.eventsBySession { eventsBySession = snapshot.eventsBySession; logCacheChanged = true }
        if historySessions != snapshot.historySessions { historySessions = snapshot.historySessions; logCacheChanged = true }
        if historyEventsBySession != snapshot.historyEventsBySession {
            historyEventsBySession = snapshot.historyEventsBySession
            logCacheChanged = true
        }
        if tasks != snapshot.tasks { tasks = snapshot.tasks }
        if inbox != snapshot.inbox { inbox = snapshot.inbox }
        if logCacheChanged { rebuildLogCache() }
        gatewayConnected = snapshot.connected
        gatewayStreaming = snapshot.streaming
        if !snapshot.connected {
            let nextPhase = ConnectionPhase.disconnected(snapshot.error ?? "Gateway에 연결되지 않았습니다.")
            if phase != nextPhase { phase = nextPhase }
        }
        reconcileSelections()
        syncPetSnapshot()
    }

    private func apply(streamMessage value: JSONValue) {
        guard let message = value.objectValue, let kind = message.string("kind") else { return }
        lastStreamMessageAt = Date()
        switch kind {
        case "event":
            if let eventValue = message["event"], let event = MonitorEvent(eventValue) {
                lastAgentEventAt = Date()
                enqueue(event)
            }
        case "state":
            var logCacheChanged = false
            if let values = message.array("sessions") {
                let nextSessions = values.compactMap(GatewaySession.init)
                if sessions != nextSessions {
                    sessions = nextSessions
                    logCacheChanged = true
                }
                let validSessionIds = Set(sessions.map(\.sessionId))
                let nextEvents = eventsBySession.filter { validSessionIds.contains($0.key) }
                if eventsBySession != nextEvents {
                    eventsBySession = nextEvents
                    logCacheChanged = true
                }
            }
            for sessionId in (message.array("removedSessionIds") ?? []).compactMap(\.stringValue) {
                if eventsBySession.removeValue(forKey: sessionId) != nil { logCacheChanged = true }
            }
            if let values = message.array("tasks") {
                let nextTasks = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "task", index: $0.offset) }
                if tasks != nextTasks { tasks = nextTasks }
            }
            if let values = message.array("inbox") {
                let nextInbox = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "inbox", index: $0.offset) }
                if inbox != nextInbox { inbox = nextInbox }
            }
            if let connected = message.bool("connected") { gatewayConnected = connected }
            if let streaming = message.bool("streaming") { gatewayStreaming = streaming }
            if gatewayConnected { updateConnectionPhase() }
            else {
                let nextPhase = ConnectionPhase.disconnected(message.string("error") ?? "Gateway 연결 끊김")
                if phase != nextPhase { phase = nextPhase }
            }
            if logCacheChanged { rebuildLogCache() }
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
        let nextPhase: ConnectionPhase
        if gatewayConnected && gatewayStreaming {
            nextPhase = .connected
        } else if gatewayConnected {
            nextPhase = .degraded("Gateway 조회 가능 · 실시간 이벤트 재연결 중")
        } else {
            nextPhase = .disconnected("Gateway에 연결되지 않았습니다.")
        }
        if phase != nextPhase { phase = nextPhase }
    }

    private func enqueue(_ event: MonitorEvent) {
        pendingStreamEvents.append(event)
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushPendingStreamEvents()
        }
    }

    private func flushPendingStreamEvents() {
        streamFlushTask = nil
        guard !pendingStreamEvents.isEmpty else { return }
        let pending = pendingStreamEvents
        pendingStreamEvents.removeAll(keepingCapacity: true)

        var nextEventsBySession = eventsBySession
        var nextLogEventsBySession = logEventsBySession
        for (sessionId, additions) in Dictionary(grouping: pending, by: \.sessionId) {
            var current = nextEventsBySession[sessionId] ?? []
            var currentSequences = Set(current.compactMap(\.sequence))
            var accepted: [MonitorEvent] = []
            accepted.reserveCapacity(additions.count)
            for event in additions {
                if let sequence = event.sequence, !currentSequences.insert(sequence).inserted { continue }
                current.append(event)
                accepted.append(event)
            }
            guard !accepted.isEmpty else { continue }
            if current.count > 2_000 { current.removeFirst(current.count - 2_000) }
            nextEventsBySession[sessionId] = current

            var logged = nextLogEventsBySession[sessionId] ?? []
            let loggedIds = Set(logged.map(\.id))
            logged.append(contentsOf: accepted.filter { !loggedIds.contains($0.id) })
            if logged.count > 2_000 { logged.removeFirst(logged.count - 2_000) }
            if logged.count > 1 { logged.sort(by: eventSort) }
            nextLogEventsBySession[sessionId] = logged
        }
        if eventsBySession != nextEventsBySession { eventsBySession = nextEventsBySession }
        if logEventsBySession != nextLogEventsBySession { logEventsBySession = nextLogEventsBySession }
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        eventsBySession.removeValue(forKey: sessionId)
        rebuildLogCache()
        reconcileSelections()
    }

    private func rebuildLogCache() {
        var sessionsById: [String: GatewaySession] = [:]
        for session in historySessions { sessionsById[session.sessionId] = session }
        for session in sessions { sessionsById[session.sessionId] = session }
        let nextSessions = Array(sessionsById.values)
            .sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }

        var nextEvents = historyEventsBySession
        for (sessionId, current) in eventsBySession {
            var eventsById: [String: MonitorEvent] = [:]
            for event in nextEvents[sessionId] ?? [] { eventsById[event.id] = event }
            for event in current { eventsById[event.id] = event }
            nextEvents[sessionId] = Array(eventsById.values).sorted(by: eventSort)
        }
        if logSessions != nextSessions { logSessions = nextSessions }
        if logEventsBySession != nextEvents { logEventsBySession = nextEvents }
    }

    private func mutateAgent(_ agent: ACPAgentCatalogItem, body: [String: JSONValue]) async {
        guard let endpoint else {
            agentCatalogError = "Gateway monitor가 아직 연결되지 않았습니다."
            return
        }
        agentCatalogMutationId = agent.registryId
        agentCatalogError = nil
        do {
            apply(try await client.mutateAgentCatalog(endpoint: endpoint, body: body))
        } catch {
            agentCatalogError = error.localizedDescription
        }
        agentCatalogMutationId = nil
    }

    private func apply(_ snapshot: ACPAgentCatalogSnapshot) {
        agentCatalog = snapshot.agents
        agentCatalogSource = snapshot.source
        agentCatalogStale = snapshot.stale
        agentCatalogError = snapshot.warning
    }

    private func startPet() {
        do {
            try pet.start(
                executablePath: settings.resolvedPetExecutablePath,
                projection: PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox)
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
            try pet.update(PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox))
            if petRunning { petError = nil }
        } catch {
            petError = "Pet 상태 공유 실패: \(error.localizedDescription)"
        }
    }

    private func reconcileSelections() {
        if let selectedFrontdoorId, !frontdoorSessions.contains(where: { $0.id == selectedFrontdoorId }) {
            self.selectedFrontdoorId = activeFrontdoors.first?.id ?? frontdoorSessions.first?.id
        } else if selectedFrontdoorId == nil {
            selectedFrontdoorId = activeFrontdoors.first?.id ?? frontdoorSessions.first?.id
        }
        if let selectedEventId,
           !eventsBySession.values.joined().contains(where: { $0.id == selectedEventId }) {
            self.selectedEventId = nil
        }
        if let selectedSessionId,
           !visibleLogSessions.contains(where: { $0.sessionId == selectedSessionId }) {
            self.selectedSessionId = selectedFrontdoor?.root?.sessionId ?? selectedFrontdoor?.workers.first?.sessionId
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
