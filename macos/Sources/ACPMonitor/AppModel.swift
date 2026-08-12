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
    /// Errors used to flash once in the connection bar and vanish before they
    /// could be read. Every notice and disconnect lands here with a timestamp,
    /// newest first, so the user can open the list and actually read them.
    @Published private(set) var noticeLog: [NoticeEntry] = []
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
    private let pet = PetController()
    private let installer = InstallerController()
    private let runtimeProvisioner = RuntimeProvisioner()
    private let runtimeUpdater = RuntimeUpdaterController()
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

    /// The Monitor API version the sidecar reported at handshake.
    var monitorApiVersionText: String { sidecar.meta?.monitorApiVersion ?? "—" }

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
        guard runtimeUpdater.isAvailable, !runtimeLoading else { return }
        runtimeLoading = true
        defer { runtimeLoading = false }
        do {
            let value = try await runtimeUpdater.run("inspect")
            runtimeInspection = RuntimeInspection(value)
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
    /// from Contents/Resources/runtime/runtime-manifest.json. nil in a
    /// source-tree/dev build that bundles no seed.
    var seedGatewayVersion: SeedGatewayVersion? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("runtime/runtime-manifest.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parseSeedManifest(data)
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
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/creverse-ai-lab/agenlynk/releases")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                appUpdateError = "확인 실패"
                return
            }
            if let release = parseGitHubReleases(data) {
                latestAppRelease = release
            } else {
                appUpdateError = "확인 실패"
            }
        } catch {
            appUpdateError = "확인 실패"
        }
    }

    /// Installs the runtime this app shipped and makes it live. Staging is
    /// idempotent, so this is safe to press when already up to date.
    func updateRuntimeFromAppSeed() async {
        guard !runtimeBusy else { return }
        guard let seedRoot = BundledRuntime.seedRuntimeRoot()?.path else {
            runtimeError = "이 빌드에는 설치할 Gateway runtime seed가 없습니다."
            return
        }
        runtimeBusy = true
        defer { runtimeBusy = false }
        runtimeError = nil
        runtimeNotice = nil
        do {
            let staged = RuntimeOperationResult(try await runtimeUpdater.run("stage", arguments: ["--seed", seedRoot]))
            guard staged.ok, let versionId = staged.versionId else {
                runtimeError = staged.errorMessage ?? "runtime staging에 실패했습니다."
                return
            }
            if runtimeInspection?.currentVersionId == versionId {
                runtimeNotice = "이미 최신 runtime(\(versionId))을 사용 중입니다."
                await loadRuntimeInspection()
                return
            }
            let activated = RuntimeOperationResult(try await runtimeUpdater.run(
                "activate", arguments: ["--version", versionId], blockers: runtimeActivationBlockers
            ))
            await finishRuntimeChange(activated, successNotice: "\(versionId)로 전환했습니다. Gateway를 다시 시작하면 적용됩니다.")
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
            let result = RuntimeOperationResult(try await runtimeUpdater.run(
                "rollback", blockers: runtimeActivationBlockers
            ))
            await finishRuntimeChange(result, successNotice: "이전 runtime으로 되돌렸습니다. Gateway를 다시 시작하면 적용됩니다.")
        } catch {
            runtimeError = error.localizedDescription
        }
    }

    private func finishRuntimeChange(_ result: RuntimeOperationResult, successNotice: String) async {
        if result.ok {
            runtimeNotice = successNotice
        } else if result.errorCode == "ACTIVATION_BLOCKED" || result.errorCode == "ROLLBACK_BLOCKED" {
            // Deferred, not failed: the same blocker rule a safe restart uses.
            let detail = runtimeActivationBlockers.joined(separator: ", ")
            runtimeError = "진행 중인 작업이 있어 적용을 보류했습니다\(detail.isEmpty ? "" : " (\(detail))"). 끝난 뒤 다시 시도하세요."
        } else if result.errorCode == "NO_PREVIOUS_TARGET" {
            runtimeError = "되돌릴 이전 runtime이 없습니다."
        } else {
            runtimeError = result.errorMessage ?? "runtime 적용에 실패했습니다."
        }
        await loadRuntimeInspection()
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

    private func connect(restartSidecar: Bool = false) async {
        phase = .starting
        reconciliationTask?.cancel()
        reconciliationTask = nil
        if restartSidecar { sidecar.stop() }
        do {
            let endpoint = try await sidecar.start(nodeOverride: settings.nodePath)
            self.endpoint = endpoint
            // A fresh monitor counts revisions from zero; a stale baseline
            // could coincide with the new numbering and skip a real change.
            appliedSnapshotRevision = nil
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
            phase = .disconnected(describeConnectFailure(error))
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

    /// Advances a heartbeat timestamp at most once per second. The published
    /// value only drives 1-second-granularity labels, so finer updates are
    /// pure re-render churn.
    private func markHeartbeat(_ heartbeat: inout Date?) {
        let now = Date()
        if heartbeat.map({ now.timeIntervalSince($0) >= 1 }) ?? true { heartbeat = now }
    }

    /// The monitor revision of the last fully-applied snapshot; nil until one
    /// applies or when the monitor predates the revision field.
    private var appliedSnapshotRevision: Int?

    private func apply(_ snapshot: MonitorSnapshot) {
        // Deliberately NOT a heartbeat update: snapshots also arrive from the
        // periodic HTTP reconciliation, which would keep the staleness signal
        // green forever even after the SSE stream silently died.
        var logCacheChanged = false
        if gateway != snapshot.gateway { gateway = snapshot.gateway }
        // The monitor's revision covers exactly the session/event data below.
        // On the 10s reconciliation an unchanged revision skips four deep
        // comparisons over every retained event (~15ms of main-thread work and
        // the cache rebuild they can trigger); tasks/inbox are outside the
        // revision and keep their own cheap checks.
        let dataUnchanged = snapshot.revision != nil && snapshot.revision == appliedSnapshotRevision
        if !dataUnchanged {
            if sessions != snapshot.sessions { sessions = snapshot.sessions; logCacheChanged = true }
            if eventsBySession != snapshot.eventsBySession { eventsBySession = snapshot.eventsBySession; logCacheChanged = true }
            if historySessions != snapshot.historySessions { historySessions = snapshot.historySessions; logCacheChanged = true }
            if historyEventsBySession != snapshot.historyEventsBySession {
                historyEventsBySession = snapshot.historyEventsBySession
                logCacheChanged = true
            }
            appliedSnapshotRevision = snapshot.revision
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
        // The UI shows these at 1-second granularity, but the stream delivers
        // 30–100 token chunks per second. Publishing every arrival would fire
        // objectWillChange per chunk and defeat the 100ms event batching by
        // re-evaluating every observing view anyway; throttle to the precision
        // the consumers actually display.
        markHeartbeat(&lastStreamMessageAt)
        switch kind {
        case "event":
            if let eventValue = message["event"], let event = MonitorEvent(eventValue) {
                markHeartbeat(&lastAgentEventAt)
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
            // Local (non-Gateway) sessions never produce "event" messages; the
            // monitor ships their rewritten buckets here instead. Replace whole
            // buckets rather than appending — the local scanner re-projects a
            // turn in place, so appending would duplicate every edited turn.
            if let buckets = message.object("events") {
                var eventsChanged = false
                for (sessionId, value) in buckets {
                    let nextEvents = (value.arrayValue ?? []).compactMap(MonitorEvent.init)
                    if nextEvents.isEmpty {
                        // An emptied bucket means the transcript window dropped
                        // it; /api/snapshot omits the key entirely, so mirror
                        // that instead of leaving an empty one behind to churn
                        // the next reconciliation's comparison.
                        if eventsBySession.removeValue(forKey: sessionId) != nil { eventsChanged = true }
                        continue
                    }
                    if eventsBySession[sessionId] == nextEvents { continue }
                    eventsBySession[sessionId] = nextEvents
                    eventsChanged = true
                }
                if eventsChanged {
                    logCacheChanged = true
                    // Local transcript growth is agent activity, and it is the
                    // only activity signal a local-only session ever emits.
                    markHeartbeat(&lastAgentEventAt)
                }
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
                if phase != nextPhase {
                    phase = nextPhase
                    recordNotice(message.string("error") ?? "Gateway 연결 끊김")
                }
            }
            // A streaming pause with the Gateway still connected is a
            // subscription drop; log its reason even though the bar only
            // turns amber for it.
            if gatewayConnected, message.bool("streaming") == false, let error = message.string("error") {
                recordNotice(error)
            }
            if logCacheChanged { rebuildLogCache() }
            reconcileSelections()
            syncPetSnapshot()
        case "gateway":
            gateway = message["gateway"]
            Task { await loadGatewayConfig() }
        case "notice":
            let text = noticeText(message["event"])
            lastNotice = text
            recordNotice(text)
        case "session_removed":
            guard let sessionId = message.string("sessionId") else { break }
            removeSession(sessionId)
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
        // Collapse a repeating error into one entry with a count instead of
        // fifty identical rows.
        if let last = noticeLog.first, last.text == text {
            noticeLog[0] = NoticeEntry(at: Date(), text: text, count: last.count + 1)
        } else {
            noticeLog.insert(NoticeEntry(at: Date(), text: text, count: 1), at: 0)
            if noticeLog.count > 50 { noticeLog.removeLast(noticeLog.count - 50) }
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
            let tail = logged.last
            let fresh = accepted.filter { !loggedIds.contains($0.id) }
            logged.append(contentsOf: fresh)
            if logged.count > 2_000 { logged.removeFirst(logged.count - 2_000) }
            // Events arrive sequence-ordered per session; the sort only needs
            // to run when this batch actually lands out of order (a replay
            // after reconnect). Re-sorting 2000 events per 100ms flush was
            // measurable main-thread time for a case that almost never occurs.
            let appendedInOrder = zip(fresh, fresh.dropFirst()).allSatisfy { !withinSessionEventOrder($1, $0) }
                && (tail == nil || fresh.first == nil || !withinSessionEventOrder(fresh.first!, tail!))
            if logged.count > 1 && !appendedInOrder { logged.sort(by: withinSessionEventOrder) }
            nextLogEventsBySession[sessionId] = logged
        }
        if eventsBySession != nextEventsBySession { eventsBySession = nextEventsBySession }
        if logEventsBySession != nextLogEventsBySession {
            logEventsBySession = nextLogEventsBySession
            invalidateEventCaches()
        }
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        eventsBySession.removeValue(forKey: sessionId)
        rebuildLogCache()
        reconcileSelections()
    }

    /// The merged per-session inputs of the last rebuild, so an unchanged
    /// session's merge (dictionary insert of every event + a sort) is skipped.
    /// Rebuilds run several times a second during a busy turn, and re-merging
    /// all sessions at the caps measured at ~200ms of main-thread stall each —
    /// while typically only one session's events actually changed.
    private var logMergeInputs: [String: (live: [MonitorEvent], history: [MonitorEvent])] = [:]

    private func rebuildLogCache() {
        var sessionsById: [String: GatewaySession] = [:]
        for session in historySessions { sessionsById[session.sessionId] = session }
        for session in sessions { sessionsById[session.sessionId] = session }
        let nextSessions = Array(sessionsById.values)
            .sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }

        var nextEvents = logEventsBySession
        var nextInputs: [String: (live: [MonitorEvent], history: [MonitorEvent])] = [:]
        let sessionIds = Set(eventsBySession.keys).union(historyEventsBySession.keys)
        for sessionId in sessionIds {
            let live = eventsBySession[sessionId] ?? []
            let history = historyEventsBySession[sessionId] ?? []
            nextInputs[sessionId] = (live, history)
            // Array equality here is cheap in the common case: unchanged
            // sessions share storage with the previous pass (CoW), so the
            // comparison is pointer identity, not element-by-element.
            if let previous = logMergeInputs[sessionId],
               previous.live == live, previous.history == history,
               nextEvents[sessionId] != nil {
                continue
            }
            var eventsById: [String: MonitorEvent] = [:]
            for event in history { eventsById[event.id] = event }
            for event in live { eventsById[event.id] = event }
            nextEvents[sessionId] = Array(eventsById.values).sorted(by: withinSessionEventOrder)
        }
        // Sessions that vanished from both sources drop out of the cache.
        for sessionId in nextEvents.keys where nextInputs[sessionId] == nil {
            nextEvents.removeValue(forKey: sessionId)
        }
        logMergeInputs = nextInputs

        if logSessions != nextSessions {
            logSessions = nextSessions
            invalidateEventCaches()
        }
        if logEventsBySession != nextEvents {
            logEventsBySession = nextEvents
            invalidateEventCaches()
        }
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
            let projection = PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox)
            // start() writes the files itself; the skip-identical baseline in
            // syncPetSnapshot must reflect that write.
            lastPetProjection = projection
            try pet.start(
                executablePath: settings.resolvedPetExecutablePath,
                projection: projection
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

    /// The projection last written to the contract files. State messages
    /// arrive several times a second during a turn, but the projection usually
    /// only changes on real state transitions — skipping identical writes
    /// spares two atomic file writes + chmods per message.
    private var lastPetProjection: PetActivityProjection?

    private func syncPetSnapshot() {
        guard settings.petEnabled, petRunning else { return }
        let projection = PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox)
        guard projection != lastPetProjection else { return }
        do {
            try pet.update(projection)
            lastPetProjection = projection
            if petRunning { petError = nil }
        } catch {
            petError = "Pet 상태 공유 실패: \(error.localizedDescription)"
        }
    }

    private func reconcileSelections() {
        // Reconcile against the SAME merged list the sidebar shows. Checking the
        // live-only `frontdoorSessions` here reassigned selectedFrontdoorId every
        // time a Frontdoor briefly left the live list, and DashboardView's
        // onChange(selectedFrontdoorId) then cleared the selected event — the
        // reported "clicking an event, it deselects on update" bug.
        let available = logFrontdoorSessions
        if let selectedFrontdoorId, !available.contains(where: { $0.id == selectedFrontdoorId }) {
            self.selectedFrontdoorId = available.first(where: \.isActive)?.id ?? available.first?.id
        } else if selectedFrontdoorId == nil {
            selectedFrontdoorId = available.first(where: \.isActive)?.id ?? available.first?.id
        }
        // Check the merged log the sequence view actually renders, not the
        // live-only buckets: a selected event whose session moved to history is
        // still on screen and must stay selected.
        if let selectedEventId,
           !logEventsBySession.values.joined().contains(where: { $0.id == selectedEventId }) {
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
