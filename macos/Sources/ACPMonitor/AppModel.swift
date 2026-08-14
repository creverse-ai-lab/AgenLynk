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
    /// Onboarding installs any subset of the built-in Frontdoors at once; at
    /// least one must stay ticked. `onboardingFrontDoor` above is kept as the
    /// legacy single value other code may still read.
    @Published var onboardingFrontdoors: Set<String> = ["codex"]
    @Published private(set) var onboardingRunning = false
    @Published private(set) var onboardingOutput: [String] = []
    @Published private(set) var onboardingError: String?
    /// Agents that already carry a Control MCP, per `/api/frontdoors`, with the
    /// exclusive primary (nil when none). Drives the Settings install-state
    /// badges; empty until `loadInstalledFrontdoors()` first succeeds.
    @Published private(set) var installedFrontdoors: [String] = []
    @Published private(set) var primaryFrontdoor: String?
    /// The agent whose Control MCP install is running right now (nil when idle),
    /// so only its row shows progress.
    @Published private(set) var installingFrontdoor: String?
    @Published private(set) var phase: ConnectionPhase = .idle
    var gateway: JSONValue? { monitorStore.state.gateway }
    var sessions: [GatewaySession] { monitorStore.state.sessions }
    var eventsBySession: [String: [MonitorEvent]] { monitorStore.state.eventsBySession }
    var historySessions: [GatewaySession] { monitorStore.state.historySessions }
    var historyEventsBySession: [String: [MonitorEvent]] { monitorStore.state.historyEventsBySession }
    var logSessions: [GatewaySession] { monitorStore.state.logSessions }
    var logEventsBySession: [String: [MonitorEvent]] { monitorStore.state.logEventsBySession }
    var tasks: [MonitorRecord] { monitorStore.state.tasks }
    var inbox: [MonitorRecord] { monitorStore.state.inbox }
    @Published var selectedFrontdoorId: String?
    @Published var selectedSessionId: String?
    @Published var selectedEventId: String?
    @Published var lastNotice: String?
    /// Errors used to flash once in the connection bar and vanish before they
    /// could be read. Every notice and disconnect lands here with a timestamp,
    /// newest first, so the user can open the list and actually read them.
    @Published private(set) var noticeLog: [NoticeEntry] = []
    var agentCatalog: [ACPAgentCatalogItem] { agentCatalogStore.agents }
    var agentCatalogLoading: Bool { agentCatalogStore.loading }
    var agentCatalogMutationId: String? { agentCatalogStore.mutationId }
    var agentCatalogSource: String { agentCatalogStore.source }
    var agentCatalogStale: Bool { agentCatalogStore.stale }
    var agentCatalogError: String? { agentCatalogStore.error }
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
    var petRunning: Bool { petStore.running }
    var petError: String? { petStore.error }
    @Published private(set) var runtimeInspection: RuntimeInspection?
    @Published private(set) var runtimeLoading = false
    @Published private(set) var runtimeBusy = false
    @Published private(set) var runtimeError: String?
    @Published private(set) var runtimeNotice: String?
    /// The newest AgenLynk release the GitHub feed advertised, or nil until a
    /// successful check finds one.
    @Published private(set) var latestAppRelease: AppReleaseInfo?
    @Published private(set) var appUpdateChecking = false
    /// A non-fatal reason the last app-update check produced no result (offline,
    /// rate-limited, unparseable). The local version stays usable regardless.
    @Published private(set) var appUpdateError: String?

    let settings = AppSettings()
    private let sidecar = SidecarController()
    private let client = MonitorClient()
    private let petStore = PetStore()
    private let installer = InstallerController()
    private let runtimeProvisioner = RuntimeProvisioner()
    private let runtimeManager = GatewayRuntimeManager()
    private let appUpdateService = AppUpdateService()
    private let agentCatalogStore = AgentCatalogStore()
    private let monitorStore = MonitorStore()
    private var storeCancellables = Set<AnyCancellable>()
    private var startupCheckStarted = false
    private var startTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var endpoint: MonitorEndpoint?
    private var sidecarStreamConnected = false
    private var sidecarRestartAttempts = 0
    private var sidecarRestartTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var isStopping = false

    init() {
        agentCatalogStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &storeCancellables)
        petStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &storeCancellables)
        monitorStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &storeCancellables)
        monitorStore.$logRevision
            .dropFirst()
            .sink { [weak self] _ in self?.invalidateEventCaches() }
            .store(in: &storeCancellables)
    }

    var gatewayVersion: String {
        gateway?.objectValue?.string("gatewayVersion") ?? "—"
    }

    /// The Monitor API version the sidecar reported at handshake.
    var monitorApiVersionText: String { sidecar.meta?.monitorApiVersion ?? "—" }

    var sidecarVersionText: String {
        guard let meta = sidecar.meta else { return "—" }
        let version = meta.sidecarVersion.isEmpty ? "—" : meta.sidecarVersion
        let build = meta.sidecarBuildId.isEmpty ? "—" : meta.sidecarBuildId
        return "\(version) · build \(build)"
    }

    var gatewayBuild: String {
        gateway?.objectValue?.string("gatewayBuildId") ?? "—"
    }

    /// Wall-clock time of the last message received from the Monitor stream,
    /// regardless of kind. This is the liveness signal the menu bar shows: it
    /// keeps ticking while agents are idle, so "no active agent" and "no data
    /// arriving" stay distinguishable.
    var lastStreamMessageAt: Date? { monitorStore.state.lastStreamMessageAt }
    /// Time of the last agent event, as opposed to a state/heartbeat message.
    var lastAgentEventAt: Date? { monitorStore.state.lastAgentEventAt }

    var streamingLive: Bool { monitorStore.state.connected && monitorStore.state.streaming }

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
        // Built from the merged log (live + retained history), not the live
        // list alone: a Frontdoor that just went idle leaves the live session
        // list but is still in history, and it must NOT vanish from the sidebar
        // unless the user asked for active-only. Vanishing also churned the
        // selection (see reconcileSelections), which cleared the picked event.
        logFrontdoorSessions.filter { !settings.activeOnly || $0.isActive }
    }

    var selectedFrontdoor: FrontdoorSession? {
        guard let selectedFrontdoorId else { return nil }
        return logFrontdoorSessions.first { $0.id == selectedFrontdoorId }
    }

    var selectedSession: GatewaySession? {
        guard let selectedSessionId else { return nil }
        return visibleLogSessions.first { $0.sessionId == selectedSessionId }
    }

    // ── Memoized event aggregations ───────────────────────────────────────
    // These are computed properties referenced from view bodies, so without a
    // cache they re-run a full flatMap+filter+sort over every retained event
    // (~100-300ms at the caps) on EVERY body evaluation — 10/s during a busy
    // turn. `dataRevision` advances whenever the underlying event data
    // changes; the cache key adds the selection and the two display filters.

    private struct EventCacheKey: Equatable {
        let revision: Int
        let frontdoorId: String?
        let showThoughts: Bool
        let showToolEvents: Bool
    }

    private var dataRevision = 0
    private var allVisibleEventsCache: (key: EventCacheKey, value: [MonitorEvent])?
    private var selectedEventsCache: (key: EventCacheKey, value: [MonitorEvent])?

    /// Call whenever `logEventsBySession`/`eventsBySession` contents change.
    private func invalidateEventCaches() {
        dataRevision &+= 1
    }

    private var eventCacheKey: EventCacheKey {
        EventCacheKey(
            revision: dataRevision,
            frontdoorId: selectedFrontdoorId,
            showThoughts: settings.showThoughts,
            showToolEvents: settings.showToolEvents
        )
    }

    var allVisibleEvents: [MonitorEvent] {
        // The selection does not affect this aggregate; exclude it from the
        // key so selecting a frontdoor doesn't recompute the full list.
        let key = EventCacheKey(
            revision: dataRevision, frontdoorId: nil,
            showThoughts: settings.showThoughts, showToolEvents: settings.showToolEvents
        )
        if let cached = allVisibleEventsCache, cached.key == key { return cached.value }
        let mappedSessionIds = Set(logFrontdoorSessions.flatMap { $0.members.map(\.sessionId) })
        let value = logEventsBySession
            .filter { mappedSessionIds.contains($0.key) }
            .values.flatMap { $0 }
            .filter(eventIsVisible)
            .sorted(by: crossSessionEventOrder)
        allVisibleEventsCache = (key, value)
        return value
    }

    var visibleEventsBySession: [String: [MonitorEvent]] {
        eventsBySession.mapValues { $0.filter(eventIsVisible) }
    }

    var selectedEvents: [MonitorEvent] {
        guard let selectedFrontdoorId,
              let frontdoor = logFrontdoorSessions.first(where: { $0.id == selectedFrontdoorId }) else {
            return allVisibleEvents
        }
        let key = eventCacheKey
        if let cached = selectedEventsCache, cached.key == key { return cached.value }
        let value = frontdoor.members
            .flatMap { logEventsBySession[$0.sessionId] ?? [] }
            .filter(eventIsVisible)
            .sorted(by: crossSessionEventOrder)
        selectedEventsCache = (key, value)
        return value
    }

    var selectedEvent: MonitorEvent? {
        guard let selectedEventId else { return nil }
        // The selected event is on screen, so it is in the selected scope;
        // searching there avoids materializing the full aggregate just to
        // resolve one id.
        return selectedEvents.first { $0.id == selectedEventId }
            ?? allVisibleEvents.first { $0.id == selectedEventId }
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
            guard !isStopping else { return }
            if settings.petEnabled && !petRunning { startPet() }
            guard startTask == nil else { return }
            connectionGeneration += 1
            let generation = connectionGeneration
            startTask = Task { [weak self] in await self?.connect(generation: generation) }
        }
    }

    /// One-time startup sequence: install/activate the bundled runtime seed
    /// (no-op in source-tree development, see RuntimeProvisioner), then
    /// decide whether an existing Control identity lets us skip straight to
    /// the dashboard or first-run onboarding is needed.
    private func performStartupCheck(forceRepair: Bool = false) async {
        startupPhase = .provisioningRuntime
        do {
            if let installed = try await runtimeProvisioner.ensureInstalled(forceRepair: forceRepair),
               let recoveryNotice = installed.recoveryNotice {
                runtimeNotice = recoveryNotice
            }
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

    /// User-confirmed recovery for the rare state where neither current.json
    /// nor the stable current symlink identifies a verified runtime. Normal
    /// startup never takes this path automatically.
    func forceRuntimeRepair() {
        guard case .runtimeError = startupPhase else { return }
        startupPhase = .provisioningRuntime
        Task { [weak self] in await self?.performStartupCheck(forceRepair: true) }
    }

    /// Runs the bundled bootstrap (--install-all --front-door <target>
    /// --refresh-registry) from the first-run onboarding surface. Monitoring
    /// only starts after the installer reports a health-verified success.
    func startOnboardingInstall() {
        guard !onboardingRunning, onboardingInstallLocationReady else { return }
        // The primary is installed with `--install-all` (adapters + registry +
        // that exclusive Frontdoor); every additional pick is added on top with
        // the additive `--install-control`. A stable order keeps the primary
        // deterministic and the output readable.
        let targets = Self.frontdoorInstallOrder.filter { onboardingFrontdoors.contains($0) }
        guard let primary = targets.first else { return }
        let extras = Array(targets.dropFirst())
        onboardingRunning = true
        onboardingError = nil
        onboardingOutput.removeAll()
        let nodeOverride = settings.nodePath
        Task { [weak self] in
            guard let self else { return }
            let append: (String) -> Void = { line in
                Task { @MainActor [weak self] in self?.appendOnboardingOutput(line) }
            }
            do {
                // Steps run strictly sequentially — the installer reuses a
                // single-shot process, so overlapping runs would collide.
                let primaryResult = try await self.installer.run(frontDoor: primary, nodeOverride: nodeOverride, onOutputLine: append)
                guard primaryResult.ok else {
                    self.onboardingRunning = false
                    self.onboardingError = primaryResult.message
                    return
                }
                for target in extras {
                    let result = try await self.installer.installControl(target: target, nodeOverride: nodeOverride, onOutputLine: append)
                    guard result.ok else {
                        self.onboardingRunning = false
                        self.onboardingError = result.message
                        return
                    }
                }
                self.onboardingRunning = false
                self.startupPhase = .ready
                self.startIfNeeded()
            } catch {
                self.onboardingRunning = false
                self.onboardingError = error.localizedDescription
            }
        }
    }

    /// Canonical Frontdoor order used wherever the built-in agents are listed
    /// or installed, so the primary and the UI rows stay deterministic.
    static let frontdoorInstallOrder = ["codex", "claude", "grok"]

    private func appendOnboardingOutput(_ line: String) {
        onboardingOutput.append(line)
        if onboardingOutput.count > 200 { onboardingOutput.removeFirst(onboardingOutput.count - 200) }
    }

    func ensureStarted() async {
        startIfNeeded()
        await startTask?.value
    }

    func reconnect(resetRestartBackoff: Bool = true) {
        guard !isStopping else { return }
        if resetRestartBackoff {
            sidecarRestartAttempts = 0
            sidecarRestartTask?.cancel()
            sidecarRestartTask = nil
        }
        connectionGeneration += 1
        let generation = connectionGeneration
        startTask?.cancel()
        reconciliationTask?.cancel()
        sidecarRestartTask?.cancel()
        endpoint = nil
        sidecarStreamConnected = false
        monitorStore.resetForNewSidecar()
        startTask = Task { [weak self] in
            await self?.connect(restartSidecar: true, generation: generation)
        }
    }

    func stop() async {
        isStopping = true
        connectionGeneration += 1
        startTask?.cancel()
        reconciliationTask?.cancel()
        sidecarRestartTask?.cancel()
        startTask = nil
        reconciliationTask = nil
        sidecarRestartTask = nil
        monitorStore.stop()
        endpoint = nil
        sidecarStreamConnected = false
        await client.stop()
        await sidecar.stop()
        petStore.stop()
        installer.cancel()
        runtimeProvisioner.cancel()
    }

    func setPetEnabled(_ enabled: Bool) {
        settings.petEnabled = enabled
        if enabled {
            startPet()
        } else {
            petStore.stop()
        }
    }

    func restartPet() {
        settings.petEnabled = true
        startPet()
    }

    func resetSettings() {
        settings.reset()
        petStore.stop()
    }

    func loadAgentCatalog(refresh: Bool = false) async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else {
            agentCatalogStore.setConnectionUnavailable()
            return
        }
        await agentCatalogStore.load(client: client, endpoint: endpoint, refresh: refresh)
    }

    func installAgent(_ agent: ACPAgentCatalogItem) async {
        await mutateAgent(agent, body: [
            "action": .string("install"),
            "registryId": .string(agent.registryId)
        ])
    }

    /// Installs one agent's Control MCP after onboarding, so a Frontdoor the
    /// user skipped at first-run starts being monitored. Additive: existing
    /// Frontdoors are left in place. Reports through the same onboarding output
    /// surface, which is idle once the app is `.ready`.
    func installFrontdoorControl(_ target: String) {
        // Only that agent's row shows progress — the installer's process is
        // single-shot, so a second install is refused while one runs, but the
        // other rows must not all read as "설치 중".
        guard installingFrontdoor == nil, !onboardingRunning, onboardingInstallLocationReady else { return }
        installingFrontdoor = target
        onboardingError = nil
        lastNotice = nil
        onboardingOutput.removeAll()
        let nodeOverride = settings.nodePath
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.installer.installControl(target: target, nodeOverride: nodeOverride) { line in
                    Task { @MainActor [weak self] in self?.appendOnboardingOutput(line) }
                }
                self.installingFrontdoor = nil
                if result.ok {
                    self.lastNotice = "\(target.capitalized) Frontdoor MCP를 설치했습니다. 새로 시작하는 세션부터 모니터링됩니다."
                    self.reconnect()
                    Task { await self.loadInstalledFrontdoors() }
                } else {
                    self.onboardingError = result.message
                }
            } catch {
                self.installingFrontdoor = nil
                self.onboardingError = error.localizedDescription
            }
        }
    }

    func setAgentEnabled(_ agent: ACPAgentCatalogItem, enabled: Bool) async {
        await mutateAgent(agent, body: [
            "action": .string("set_enabled"),
            "providerId": .string(agent.providerId),
            "enabled": .bool(enabled)
        ])
    }

    /// Refreshes the installed-Frontdoor snapshot for the Settings badges. The
    /// endpoint must be up first (like `loadGatewayConfig`); any failure is a
    /// non-fatal debug — an install-state read must never break Settings.
    func loadInstalledFrontdoors() async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else { return }
        do {
            let snapshot = try await client.fetchInstalledFrontdoors(endpoint: endpoint)
            installedFrontdoors = snapshot.installed
            primaryFrontdoor = snapshot.primary
        } catch {
            // Non-fatal: the badges just stay at their last known state rather
            // than surfacing an error into Settings.
            #if DEBUG
            FileHandle.standardError.write(Data("loadInstalledFrontdoors failed: \(error.localizedDescription)\n".utf8))
            #endif
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

    /// Mirrors `MonitorState.restartBlockers()`. Activation and rollback are
    /// held back for exactly the same reasons a safe restart is.
    var runtimeActivationBlockers: [String] {
        // These lists mirror the monitor stream; when it is not connected they
        // are empty or stale, which is indistinguishable from "no active work".
        // The updater trusts the blockers it is handed, so an unknown Gateway
        // state must count as a blocker, not as an all-clear.
        guard case .connected = phase else { return ["Gateway 상태 확인 불가 (연결 안 됨)"] }
        return restartBlockerLabels(sessions: sessions, tasks: tasks, inbox: inbox)
    }

    func loadRuntimeInspection() async {
        guard runtimeManager.isAvailable, !runtimeLoading else { return }
        runtimeLoading = true
        defer { runtimeLoading = false }
        do {
            runtimeInspection = try await runtimeManager.inspect()
            runtimeError = nil
        } catch {
            runtimeError = error.localizedDescription
        }
    }

    // MARK: - Unified update surface (app / gateway seed / adapters)

    /// The running app's own short version, e.g. `"0.3.4"`.
    var localAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// True when the GitHub feed advertises a strictly-newer release than the
    /// running app. A running `.app` cannot safely replace itself, so this only
    /// drives a download-and-notify action, never an auto-install.
    var appUpdateAvailable: Bool {
        guard let latest = latestAppRelease else { return false }
        return compareSemanticVersions(localAppVersion, latest.version) == .orderedAscending
    }

    /// The Gateway version+build the app bundle ships as its runtime seed, read
    /// from Contents/Resources/gateway-seed/runtime-manifest.json. nil in a
    /// source-tree/dev build that bundles no seed.
    var seedGatewayVersion: SeedGatewayVersion? {
        runtimeManager.seedGatewayVersion
    }

    /// True when the installed runtime's build differs from the seed the app
    /// ships — i.e. `updateRuntimeFromAppSeed()` would install something new.
    var gatewayUpdateAvailable: Bool {
        guard let seed = seedGatewayVersion,
              let installedBuild = runtimeInspection?.current?.gatewayBuildId else { return false }
        return installedBuild != seed.gatewayBuildId
    }

    /// How many installed adapters have a newer registry version available.
    var adapterUpdateCount: Int {
        agentCatalog.filter(\.updateAvailable).count
    }

    /// Checks the public GitHub releases feed for a newer AgenLynk build.
    /// Includes pre-releases (the repo may be pre-release-only, so
    /// `/releases/latest` 404s) and never throws to the caller: offline,
    /// rate-limit, and parse failures all resolve to `appUpdateError`.
    func checkAppUpdate() async {
        guard !appUpdateChecking else { return }
        appUpdateChecking = true
        appUpdateError = nil
        defer { appUpdateChecking = false }
        do {
            latestAppRelease = try await appUpdateService.latestRelease()
        } catch {
            appUpdateError = "확인 실패"
        }
    }

    /// Installs the runtime this app shipped and makes it live. Staging is
    /// idempotent, so this is safe to press when already up to date.
    func updateRuntimeFromAppSeed() async {
        guard !runtimeBusy else { return }
        guard runtimeManager.isAvailable else {
            runtimeError = "이 빌드에는 설치할 Gateway runtime seed가 없습니다."
            return
        }
        runtimeBusy = true
        defer { runtimeBusy = false }
        runtimeError = nil
        runtimeNotice = nil
        do {
            let change = try await runtimeManager.activateBundledSeed(
                currentVersionId: runtimeInspection?.currentVersionId,
                blockers: runtimeActivationBlockers
            )
            finishRuntimeChange(change)
        } catch {
            runtimeError = error.localizedDescription
        }
    }

    func rollbackRuntime() async {
        guard !runtimeBusy else { return }
        runtimeBusy = true
        defer { runtimeBusy = false }
        runtimeError = nil
        runtimeNotice = nil
        do {
            finishRuntimeChange(try await runtimeManager.rollback(blockers: runtimeActivationBlockers))
        } catch {
            runtimeError = error.localizedDescription
        }
    }

    private func finishRuntimeChange(_ change: GatewayRuntimeChange) {
        runtimeInspection = change.inspection ?? runtimeInspection
        switch change.outcome {
        case let .activated(versionId):
            runtimeNotice = "\(versionId)로 전환했습니다. Gateway를 다시 시작하면 적용됩니다."
        case .rolledBack:
            runtimeNotice = "이전 runtime으로 되돌렸습니다. Gateway를 다시 시작하면 적용됩니다."
        case let .alreadyCurrent(versionId):
            runtimeNotice = "이미 최신 runtime(\(versionId))을 사용 중입니다."
        case .blocked:
            let detail = runtimeActivationBlockers.joined(separator: ", ")
            runtimeError = "진행 중인 작업이 있어 적용을 보류했습니다\(detail.isEmpty ? "" : " (\(detail))"). 끝난 뒤 다시 시도하세요."
        case .noPrevious:
            runtimeError = "되돌릴 이전 runtime이 없습니다."
        case let .failed(message):
            runtimeError = message
        }
    }

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
            if values.keys.contains(where: isMonitorConfigOption) { reconnect() }
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
            if ids.contains(where: isMonitorConfigOption) { reconnect() }
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

    private func isMonitorConfigOption(_ id: String) -> Bool {
        ["localScannerEnabled", "localScanIntervalMs", "localDiscoveryIntervalMs", "localTranscriptWindowMs", "localTranscriptRecordLimit"].contains(id)
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

    /// The stable failure code of any error the monitor path can throw.
    /// Lives here rather than in Models.swift because the error types span
    /// files that the check harness compiles as separate units.
    nonisolated static func monitorFailureCode(_ error: Error) -> String? {
        switch error {
        case let decode as MonitorDecodeError: decode.stableCode
        case let client as MonitorClientError: client.code
        case let sidecar as SidecarError: sidecar.stableCode
        case let runtime as BundledRuntimeError: runtime.stableCode
        default: nil
        }
    }

    /// A disconnect message with its actionable guidance attached, when the
    /// failure maps to a stable code the user can do something about.
    private func describeConnectFailure(_ error: Error) -> String {
        let base = error.localizedDescription
        guard let guidance = monitorFailureGuidance(code: Self.monitorFailureCode(error)) else { return base }
        return "\(base) \(guidance)"
    }

    private func connectionIsCurrent(_ generation: Int) -> Bool {
        !isStopping && !Task.isCancelled && connectionGeneration == generation
    }

    private func connect(restartSidecar: Bool = false, generation: Int) async {
        guard connectionIsCurrent(generation) else { return }
        phase = .starting
        reconciliationTask?.cancel()
        reconciliationTask = nil
        if restartSidecar {
            await sidecar.stop()
            guard connectionIsCurrent(generation) else { return }
        }
        do {
            let endpoint = try await sidecar.start(nodeOverride: settings.nodePath)
            guard connectionIsCurrent(generation) else { return }
            self.endpoint = endpoint
            // A fresh monitor counts revisions from zero; a stale baseline
            // could coincide with the new numbering and skip a real change.
            monitorStore.resetForNewSidecar()
            sidecarStreamConnected = false
            // Authenticated compatibility handshake before any normal
            // snapshot/stream consumption; throws a stable update-required
            // error if the Monitor's schema/API major isn't supported.
            _ = try await client.fetchMeta(endpoint: endpoint)
            guard connectionIsCurrent(generation) else { return }
            guard let snapshot = try await client.fetchSnapshot(endpoint: endpoint) else {
                throw MonitorDecodeError.invalidMessage
            }
            guard connectionIsCurrent(generation) else { return }
            apply(snapshot)
            await loadGatewayConfig()
            guard connectionIsCurrent(generation) else { return }
            await client.startStream(endpoint: endpoint, onMessage: { [weak self] value in
                guard let self, self.connectionIsCurrent(generation) else { return }
                self.apply(streamMessage: value)
            }, onState: { [weak self] connected, error in
                guard let self, self.connectionIsCurrent(generation) else { return }
                self.sidecarStreamConnected = connected
                if !connected {
                    self.phase = .disconnected(error ?? "Dashboard 데이터 스트림이 끊겼습니다.")
                    Task { [weak self] in
                        await self?.restartSidecarIfExited(generation: generation)
                    }
                } else {
                    self.sidecarRestartTask?.cancel()
                    self.sidecarRestartTask = nil
                    self.updateConnectionPhase()
                }
            })
            guard connectionIsCurrent(generation) else { return }
            startReconciliation(endpoint: endpoint, generation: generation)
        } catch {
            guard connectionIsCurrent(generation) else { return }
            monitorStore.setConnection(connected: false, streaming: false)
            sidecarStreamConnected = false
            phase = .disconnected(describeConnectFailure(error))
        }
    }

    private func startReconciliation(endpoint: MonitorEndpoint, generation: Int) {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.connectionIsCurrent(generation),
                      self.endpoint?.baseURL == endpoint.baseURL else { return }
                do {
                    guard let snapshot = try await self.client.fetchSnapshot(
                        endpoint: endpoint,
                        ifRevision: self.monitorStore.state.appliedSnapshotRevision
                    ) else { continue }
                    guard self.connectionIsCurrent(generation) else { return }
                    self.apply(snapshot)
                    self.sidecarRestartAttempts = 0
                    self.updateConnectionPhase()
                } catch {
                    if !(await self.sidecar.isRunning()) {
                        await self.restartSidecarIfExited(generation: generation)
                        return
                    }
                    // SSE의 재연결 상태가 사용자에게 노출된다. Snapshot 보정 실패는
                    // 다음 주기에 다시 시도해 일시적인 경합으로 Live를 끊지 않는다.
                }
            }
        }
    }

    private func restartSidecarIfExited(generation: Int) async {
        guard connectionIsCurrent(generation), !(await sidecar.isRunning()), sidecarRestartTask == nil else { return }
        sidecarRestartAttempts += 1
        let exponent = min(sidecarRestartAttempts - 1, 4)
        let delay = UInt64(500_000_000) * UInt64(1 << exponent)
        sidecarRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.connectionIsCurrent(generation) else { return }
            self.sidecarRestartTask = nil
            self.reconnect(resetRestartBackoff: false)
        }
    }

    private func apply(_ snapshot: MonitorSnapshot) {
        // HTTP reconciliation is deliberately not a stream heartbeat.
        let effect = monitorStore.apply(snapshot)
        if let error = effect.disconnectedError {
            let nextPhase = ConnectionPhase.disconnected(error)
            if phase != nextPhase { phase = nextPhase }
        }
        reconcileSelections()
        syncPetSnapshot()
    }

    private func apply(streamMessage value: JSONValue) {
        guard let message = value.objectValue, let kind = message.string("kind") else { return }
        monitorStore.markStreamMessage()
        switch kind {
        case "event":
            if let eventValue = message["event"], let event = MonitorEvent(eventValue) {
                monitorStore.enqueue(event)
            }
        case "state":
            let effect = monitorStore.applyStateMessage(message)
            if monitorStore.state.connected { updateConnectionPhase() }
            else if let error = effect.disconnectedError {
                let nextPhase = ConnectionPhase.disconnected(error)
                if phase != nextPhase {
                    phase = nextPhase
                    recordNotice(error)
                }
            }
            if let notice = effect.pausedSubscriptionNotice { recordNotice(notice) }
            reconcileSelections()
            syncPetSnapshot()
        case "gateway":
            monitorStore.setGateway(message["gateway"])
            Task { await loadGatewayConfig() }
        case "notice":
            let text = noticeText(message["event"])
            lastNotice = text
            recordNotice(text)
        case "session_removed":
            guard let sessionId = message.string("sessionId") else { break }
            monitorStore.removeSession(sessionId)
            reconcileSelections()
            syncPetSnapshot()
        default:
            break
        }
    }

    /// Human-readable text for a monitor `notice` event.
    private func noticeText(_ event: JSONValue?) -> String {
        guard let object = event?.objectValue else { return "일부 이벤트를 다시 불러오지 못했습니다." }
        if let error = object.string("error") { return error }
        if object.string("type") == "subscription_replay_truncated" {
            return "재연결 사이의 이벤트 일부가 보관 한도를 지나 유실되었습니다."
        }
        return "일부 이벤트를 다시 불러오지 못했습니다."
    }

    private func recordNotice(_ text: String) {
        NoticeEntry.record(text, at: Date(), into: &noticeLog)
    }

    private func updateConnectionPhase() {
        guard sidecarStreamConnected else { return }
        let nextPhase: ConnectionPhase
        if monitorStore.state.connected && monitorStore.state.streaming {
            nextPhase = .connected
        } else if monitorStore.state.connected {
            nextPhase = .degraded("Gateway 조회 가능 · 실시간 이벤트 재연결 중")
        } else {
            nextPhase = .disconnected("Gateway에 연결되지 않았습니다.")
        }
        if phase != nextPhase { phase = nextPhase }
    }

    private func mutateAgent(_ agent: ACPAgentCatalogItem, body: [String: JSONValue]) async {
        guard let endpoint else {
            agentCatalogStore.setConnectionUnavailable()
            return
        }
        await agentCatalogStore.mutate(client: client, endpoint: endpoint, agent: agent, body: body)
    }

    private func startPet() {
        petStore.start(
            executablePath: settings.resolvedPetExecutablePath,
            projection: PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox),
            enabled: { [weak self] in self?.settings.petEnabled == true }
        )
    }

    private func syncPetSnapshot() {
        petStore.sync(
            projection: PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox),
            enabled: settings.petEnabled
        )
    }

    private func reconcileSelections() {
        // Reconcile against the SAME merged list the sidebar shows. Checking the
        // live-only `frontdoorSessions` here reassigned selectedFrontdoorId every
        // time a Frontdoor briefly left the live list, and DashboardView's
        // onChange(selectedFrontdoorId) then cleared the selected event — the
        // reported "clicking an event, it deselects on update" bug.
        let next = MonitorSelection.reconcile(
            selectedFrontdoorId: selectedFrontdoorId,
            selectedEventId: selectedEventId,
            liveSessions: sessions,
            historySessions: historySessions,
            liveEvents: eventsBySession,
            historyEvents: historyEventsBySession
        )
        if selectedFrontdoorId != next.frontdoorId { selectedFrontdoorId = next.frontdoorId }
        if selectedEventId != next.eventId { selectedEventId = next.eventId }
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
