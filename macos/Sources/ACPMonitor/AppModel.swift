#if DEBUG
import AppKit
#endif
import Combine
import Foundation
import LynkArt

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
    /// Onboarding installs any subset of the built-in Frontdoors at once; at
    /// least one must stay ticked.
    @Published var onboardingFrontdoors: Set<String> = ["codex"]
    @Published private(set) var onboardingRunning = false
    @Published private(set) var onboardingOutput: [String] = []
    @Published private(set) var onboardingError: String?
    /// Agents that already carry a Control MCP, per `/api/frontdoors`, with the
    /// exclusive primary (nil when none). Drives the Settings install-state
    /// badges; empty until `loadInstalledFrontdoors()` first succeeds.
    @Published private(set) var installedFrontdoors: [String] = []
    /// Agents carrying only the guide MCP (not Frontdoors), per `/api/frontdoors`.
    @Published private(set) var guideOnlyFrontdoors: [String] = []
    @Published private(set) var primaryFrontdoor: String?
    /// Agent MCP entries still launching an old runtime version, per
    /// `/api/frontdoors`; Settings offers to relink them all at once.
    @Published private(set) var staleFrontdoorEntries: [StaleFrontdoorEntry] = []
    /// The agent-delegator skill in each Main CLI, per `/api/skill`.
    @Published private(set) var delegatorSkill: DelegatorSkillStatus?
    @Published private(set) var delegatorSkillUpdating = false
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
    @Published private(set) var hookStatus: MonitoringHookStatus?
    @Published private(set) var hookMutatingProvider: String?
    @Published private(set) var hookError: String?
    /// Monitoring hooks chosen during onboarding, applied once the sidecar is up.
    /// Explicit opt-in: starts empty. Leaving it empty records nothing, so the
    /// CLIs stay "아직 켜지 않음" and the app asks again later.
    @Published var onboardingMonitoringHooks: Set<String> = []
    private var pendingHookConsent: Set<String>?
    /// Asks an existing user (after an update) whether to turn hooks on.
    @Published var hookConsentPresented = false
    /// On-disk monitor history (settings > 모니터링 > 기록).
    @Published private(set) var historyStats: MonitorHistoryStats?
    @Published private(set) var historyStatsError: String?
    @Published private(set) var historyClearing = false
    /// Set when the user turned disk history off and agreed to delete what is
    /// there: the file goes once the restarted sidecar no longer has it open.
    private var diskHistoryDeletionPending = false
    /// "지난 기록" browsing: persisted sessions paged newest first from
    /// /api/history, and the events of the ones the user opened.
    @Published private(set) var browsedHistory: [GatewaySession] = [] {
        didSet { browsedHistoryRevision &+= 1 }
    }
    /// Advances with every change to `browsedHistory`; the derived views
    /// that group it (history rows, expired Workers) rebuild on it.
    private var browsedHistoryRevision = 0
    @Published private(set) var historyHasMore = true
    private var historyCursor: (updatedAt: String, sessionId: String)?
    @Published private(set) var historyLoading = false
    @Published private(set) var historyError: String?
    /// Events of the open history group plus the few groups opened most
    /// recently (`browsedRecency`); older ones are dropped, not kept forever.
    @Published private(set) var browsedEvents: [String: [MonitorEvent]] = [:] {
        didSet { browsedRevision &+= 1 }
    }
    private var browsedRevision = 0
    /// Recently opened scopes of browsed events: a history group
    /// ("history:<id>") or a listed Frontdoor's expired Workers
    /// ("frontdoor:<id>"), with the sessions each one loaded.
    private var browsedRecency = RecentKeys(capacity: MonitorReducerDefaults.browsedSessionLimit)
    private var browsedScopeSessions: [String: Set<String>] = [:]
    /// A "지난 기록" group opened from the sidebar (a `HistoryGroups` row
    /// id); while set, the center views show that group instead of the
    /// selected Frontdoor.
    @Published private(set) var selectedHistoryGroupId: String?
    /// The member of the opened history group picked in the sequence (a
    /// lane click); nil means the group's preferred session.
    @Published var selectedHistoryMemberId: String?
    /// Sessions whose older events are being fetched right now.
    @Published private(set) var olderLoadingSessionIds: Set<String> = []
    /// Sessions whose oldest event is already loaded.
    private var olderExhaustedSessionIds: Set<String> = []
    /// Sessions whose paged-in window is full (`pagedEventLimit`): older
    /// events exist but are not kept in memory.
    @Published private(set) var olderCappedSessionIds: Set<String> = []
    private static let olderPageSize = 200
    private static let historyPageSize = 50
    private var hookConsentAsked = false
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
    /// What "옛 런타임 정리" would remove now; refreshed with the inspection.
    @Published private(set) var runtimePrunePreview: RuntimePrunePlan?
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
    /// The panel hanging from the notch; created on first use.
    private(set) lazy var notchChat = NotchChatController(model: self)
    private let settingsWindow = SettingsWindowPresenter()
    private let sessionWindows = SessionDetailWindowPresenter()
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
        #if DEBUG
        // Debug-only: how often the model and the settings announce changes,
        // one line per second, to find what keeps views re-rendering.
        if let path = ProcessInfo.processInfo.environment["ACP_LYNK_DEBUG_PUBLISH"] {
            var counts = (model: 0, settings: 0, monitor: 0, pet: 0, catalog: 0)
            objectWillChange.sink { counts.model += 1 }.store(in: &storeCancellables)
            settings.objectWillChange.sink { counts.settings += 1 }.store(in: &storeCancellables)
            monitorStore.objectWillChange.sink { counts.monitor += 1 }.store(in: &storeCancellables)
            petStore.objectWillChange.sink { counts.pet += 1 }.store(in: &storeCancellables)
            agentCatalogStore.objectWillChange.sink { counts.catalog += 1 }.store(in: &storeCancellables)
            Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { _ in
                let line = "\(Date().timeIntervalSince1970) model=\(counts.model) settings=\(counts.settings) monitor=\(counts.monitor) pet=\(counts.pet) catalog=\(counts.catalog)\n"
                counts = (0, 0, 0, 0, 0)
                DebugLog.append(line, to: path)
            }.store(in: &storeCancellables)
            if let path = ProcessInfo.processInfo.environment["ACP_LYNK_DEBUG_MASCOTS"] {
                Task { @MainActor in AgentMascotSheet.write(to: path) }
            }
            if let target = ProcessInfo.processInfo.environment["ACP_LYNK_DEBUG_JUMP"] {
                // Jump to a session's window and record which app is in front.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    guard let self, let session = self.sessions.first(where: { $0.sessionId.contains(target) }) else {
                        try? "no session \(target)".write(toFile: "/tmp/agenlynk-jump.txt", atomically: true, encoding: .utf8)
                        return
                    }
                    let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
                    let host = session.pid.flatMap { SessionWindowJumper.hostApp(of: pid_t($0))?.localizedName } ?? "-"
                    let outcome = SessionWindowJumper.jump(to: session)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
                    try? "pid=\(session.pid.map(String.init) ?? "-") host=\(host) outcome=\(outcome) before=\(before) after=\(after)"
                        .write(toFile: "/tmp/agenlynk-jump.txt", atomically: true, encoding: .utf8)
                }
            }
            if ProcessInfo.processInfo.environment["ACP_LYNK_DEBUG_OPEN_SETTINGS"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    NotchChatController.openSettings()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    // Frames of the whole settings window (toolbar tabs too).
                    let windows = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") \($0.title) \($0.isVisible)" }
                    try? windows.joined(separator: "\n").write(toFile: "/tmp/agenlynk-windows.txt", atomically: true, encoding: .utf8)
                    guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "agenlynk-settings" }),
                          let frameView = window.contentView?.superview else { return }
                    for index in 0..<20 {
                        if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                            frameView.cacheDisplay(in: frameView.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/agenlynk-settings-\(index).png"))
                        }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
            }
        }
        #endif
        NotificationCenter.default.publisher(for: .openSessionDetail)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, let sessionId = note.object as? String else { return }
                self.sessionWindows.show(model: self, sessionId: sessionId)
            }
            .store(in: &storeCancellables)
        NotificationCenter.default.publisher(for: .openSurfacesSettings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settingsWindow.show(model: self, tab: .surfaces)
            }
            .store(in: &storeCancellables)
        monitorStore.$logRevision
            .dropFirst()
            .sink { [weak self] _ in self?.invalidateEventCaches() }
            .store(in: &storeCancellables)
        // A session that leaves the live log moves to disk history; without a
        // reload it would be in neither the sidebar nor "지난 기록".
        monitorStore.$state
            .map { Set($0.logSessions.map(\.sessionId)) }
            .removeDuplicates()
            .scan((Set<String>(), Set<String>())) { ($0.1, $1) }
            .filter { previous, current in !previous.subtracting(current).isEmpty }
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.mergeNewestHistoryPage() } }
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

    /// When the Monitor stream last delivered anything (the menu bar's
    /// liveness signal: it keeps ticking while agents are idle, so "no active
    /// agent" and "no data arriving" stay distinguishable) and when an agent
    /// event last changed. Deliberately NOT forwarded into this model's
    /// `objectWillChange`: only the views printing these clocks observe it.
    var heartbeat: MonitorHeartbeat { monitorStore.heartbeat }

    var streamingLive: Bool { monitorStore.state.connected && monitorStore.state.streaming }

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

    var gatewayConfigPendingApply: Bool { gatewayConfigOptions.contains { $0.pending } }
    var gatewayConfigLockedCount: Int { gatewayConfigOptions.filter { !$0.editable }.count }
    var onboardingInstallLocationReady: Bool { BundledRuntime.installationLocationReady }

    // ── Derived session views, cached per store revision ──────────────────
    // Several of these are read many times per render (sidebar, metric strip,
    // menu bar, selection reconciliation, the Pet). They depend only on the
    // monitor state, so each is built once per published state change.

    private struct DerivedCache {
        var revision = -1
        /// `browsedHistoryRevision` the entries were built against.
        var historyRevision = -1
        var frontdoorSessions: [FrontdoorSession]?
        var realtimeSessions: [GatewaySession]?
        var realtimeInbox: [MonitorRecord]?
        var visibleLogSessions: [GatewaySession]?
        /// The merged log's Frontdoors before expired Workers join them.
        var listedFrontdoorSessions: [FrontdoorSession]?
        var logFrontdoorSessions: [FrontdoorSession]?
        var historyGroups: HistoryGroups?
        var menuBarPipeline: MenuBarPipeline?
        var dashboardPipeline: MenuBarPipeline?
        /// 그래프 layouts by scope (a Frontdoor, a history session, or all).
        var dashboardGraphs: [String: DashboardGraph] = [:]
    }
    private var derivedCache = DerivedCache()

    /// Drops every derived view once the monitor state or the browsed
    /// history changed since it was built.
    private func refreshDerivedCache() {
        if derivedCache.revision != monitorStore.revision || derivedCache.historyRevision != browsedHistoryRevision {
            derivedCache = DerivedCache(revision: monitorStore.revision, historyRevision: browsedHistoryRevision)
        }
    }

    private func derived<T>(_ keyPath: WritableKeyPath<DerivedCache, T?>, _ make: () -> T) -> T {
        refreshDerivedCache()
        if let cached = derivedCache[keyPath: keyPath] { return cached }
        let value = make()
        derivedCache[keyPath: keyPath] = value
        return value
    }

    var frontdoorSessions: [FrontdoorSession] {
        derived(\.frontdoorSessions) { FrontdoorSession.make(sessions: sessions.filter { !$0.isInternalReview }) }
    }
    var activeFrontdoors: [FrontdoorSession] { frontdoorSessions.filter(\.isActive) }
    var realtimeSessions: [GatewaySession] {
        derived(\.realtimeSessions) {
            let liveCandidates = sessions.filter { !$0.isInternalReview }
            let activeFrontdoorIds = Set(liveCandidates.filter(\.isActive).compactMap(\.openerInstanceId))
            return liveCandidates
                .filter { session in
                    session.isRealtimeVisible || (session.isFrontdoorRecord && activeFrontdoorIds.contains(session.openerInstanceId ?? ""))
                }
                .sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        }
    }
    var realtimeInbox: [MonitorRecord] {
        derived(\.realtimeInbox) {
            let sessionIds = Set(realtimeSessions.map(\.sessionId))
            return inbox.filter { record in
                guard let sessionId = record.sessionId else { return false }
                return sessionIds.contains(sessionId)
            }
        }
    }
    /// The menu bar's pipelines, rebuilt only when the monitor state changes
    /// (a heartbeat no longer counts as one).
    /// The names the user gave, for the Pet (Frontdoors and sessions are named apart).
    private var petNickname: (String, String) -> String? {
        { [settings] id, role in
            role == "frontdoor"
                ? (settings.hasFrontdoorNickname(id: id) ? settings.frontdoorName(id: id, auto: "") : nil)
                : settings.sessionNickname(id: id)
        }
    }

    var menuBarPipeline: MenuBarPipeline {
        derived(\.menuBarPipeline) {
            MenuBarPipeline.make(frontdoors: frontdoorSessions, eventsBySession: eventsBySession)
        }
    }
    /// The dashboard 현황 cards: the menu bar's pipelines, but over the
    /// sidebar's Frontdoors (live + retained history), so every row in the
    /// list has its card.
    var dashboardPipeline: MenuBarPipeline {
        derived(\.dashboardPipeline) {
            MenuBarPipeline.make(frontdoors: logFrontdoorSessions, eventsBySession: logEventsBySession)
        }
    }
    /// The 그래프 view's layout for a scope, built once per monitor revision.
    /// `scope` must name everything `make` reads beyond the monitor state.
    func dashboardGraph(scope: String, _ make: () -> DashboardGraph) -> DashboardGraph {
        refreshDerivedCache()
        if let cached = derivedCache.dashboardGraphs[scope] { return cached }
        let value = make()
        derivedCache.dashboardGraphs[scope] = value
        return value
    }
    var realtimeACPCount: Int { realtimeSessions.filter { !$0.isLocalSource }.count }
    var realtimeLocalCount: Int { realtimeSessions.filter(\.isLocalSource).count }
    var pendingInbox: [MonitorRecord] { inbox.filter { $0.status == "pending" || $0.status == "interrupted" } }
    var visibleLogSessions: [GatewaySession] {
        derived(\.visibleLogSessions) { logSessions.filter { !$0.isInternalReview } }
    }
    private var listedFrontdoorSessions: [FrontdoorSession] {
        derived(\.listedFrontdoorSessions) { FrontdoorSession.make(sessions: visibleLogSessions) }
    }
    /// The sidebar's Frontdoors (live + retained history), each with the
    /// Workers of its group that are only on disk any more (§10): a Worker
    /// whose retention ran out stays under its Frontdoor.
    var logFrontdoorSessions: [FrontdoorSession] {
        derived(\.logFrontdoorSessions) {
            let expired = historyGroups.expiredWorkers
            guard !expired.isEmpty else { return listedFrontdoorSessions }
            return listedFrontdoorSessions.map { $0.addingWorkers(expired[$0.id] ?? []) }
        }
    }
    /// "지난 기록" grouped into Frontdoor-level rows, plus the expired
    /// Workers that join a listed Frontdoor instead.
    var historyGroups: HistoryGroups {
        derived(\.historyGroups) {
            HistoryGroups.make(
                browsed: browsedHistory,
                listed: visibleLogSessions,
                listedFrontdoorIds: Set(listedFrontdoorSessions.map(\.id).filter { $0 != FrontdoorSession.unattributedId })
            )
        }
    }
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
        // An expired Worker of the selected Frontdoor is selectable too.
        return visibleLogSessions.first { $0.sessionId == selectedSessionId }
            ?? selectedFrontdoor?.workers.first { $0.sessionId == selectedSessionId }
    }

    // ── Memoized event aggregations ───────────────────────────────────────
    // These are computed properties referenced from view bodies, so without a
    // cache they re-run a full flatMap+filter+sort over every retained event
    // (~100-300ms at the caps) on EVERY body evaluation — 10/s during a busy
    // turn. `dataRevision` advances whenever the underlying event data
    // changes; the cache key adds the selection and the two display filters.

    private struct EventCacheKey: Equatable {
        let revision: Int
        /// Browsed events and browsed history: a scope's expired or history
        /// members read them.
        var browsedRevision = 0
        var historyRevision = 0
        let frontdoorId: String?
        let showThoughts: Bool
        let showToolEvents: Bool
    }

    private var dataRevision = 0

    /// Advances whenever any event a timeline can show changes (the merged
    /// log or a browsed history session); views memoize their derived rows
    /// against it.
    var eventsRevision: Int { dataRevision &+ browsedRevision }
    private var allVisibleEventsCache: (key: EventCacheKey, value: [MonitorEvent])?
    private var selectedEventsCache: (key: EventCacheKey, value: [MonitorEvent])?

    /// Call whenever `logEventsBySession`/`eventsBySession` contents change.
    private func invalidateEventCaches() {
        dataRevision &+= 1
    }

    private var eventCacheKey: EventCacheKey {
        EventCacheKey(
            revision: dataRevision,
            browsedRevision: browsedRevision,
            historyRevision: browsedHistoryRevision,
            frontdoorId: selectedHistoryGroupId.map { "history:\($0)" } ?? selectedFrontdoorId,
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

    var selectedEvents: [MonitorEvent] {
        let scope: FrontdoorSession
        if selectedHistoryGroupId != nil {
            guard let group = selectedHistoryGroup else { return [] }
            scope = group
        } else if let selectedFrontdoorId,
                  let frontdoor = logFrontdoorSessions.first(where: { $0.id == selectedFrontdoorId }) {
            scope = frontdoor
        } else {
            return allVisibleEvents
        }
        let key = eventCacheKey
        if let cached = selectedEventsCache, cached.key == key { return cached.value }
        let value = scope.members
            .flatMap { logEventsBySession[$0.sessionId] ?? browsedEvents[$0.sessionId] ?? [] }
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

    /// Any session the dashboard can show: the merged log first, then the
    /// history records browsed from disk.
    func knownSession(_ sessionId: String) -> GatewaySession? {
        visibleLogSessions.first { $0.sessionId == sessionId }
            ?? browsedHistory.first { $0.sessionId == sessionId }
    }

    /// The opened "지난 기록" group, as it groups now.
    var selectedHistoryGroup: FrontdoorSession? {
        guard let selectedHistoryGroupId else { return nil }
        return historyGroups.rows.first { $0.id == selectedHistoryGroupId }
    }

    /// The session the context strip and inspector describe while a history
    /// group is open: the member picked in the sequence, else the group's
    /// preferred one (its Frontdoor).
    var selectedHistorySession: GatewaySession? {
        guard let group = selectedHistoryGroup else { return nil }
        return selectedHistoryMemberId.flatMap { id in group.members.first { $0.sessionId == id } }
            ?? group.preferredSession
    }

    /// "지난 기록" rows: Frontdoor-level groups of browsed history, minus
    /// what the sidebar already lists, so one session never shows twice and
    /// a Worker never shows as a row of its own.
    var historyRows: [FrontdoorSession] { historyGroups.rows }

    // ── Older events & history ────────────────────────────────────────────

    /// Loaded events of a session, wherever they live.
    private func loadedEvents(_ sessionId: String) -> [MonitorEvent] {
        browsedEvents[sessionId] ?? logEventsBySession[sessionId] ?? []
    }

    /// Whether scrolling to the top could still reveal older events.
    func mayHaveOlderEvents(_ sessionId: String) -> Bool {
        guard !olderExhaustedSessionIds.contains(sessionId) else { return false }
        return EventTimeline.olderCursor(in: loadedEvents(sessionId)) != nil
    }

    func mayHaveOlderEvents(in sessionIds: [String]) -> Bool {
        sessionIds.contains { mayHaveOlderEvents($0) }
    }

    /// Pages in the next older events of each given session (the sequence
    /// view reached its top). Returns whether anything new arrived.
    @discardableResult
    func loadOlderEvents(sessionIds: [String]) async -> Bool {
        guard let endpoint else { return false }
        var arrived = false
        for sessionId in Set(sessionIds) where mayHaveOlderEvents(sessionId) && !olderLoadingSessionIds.contains(sessionId) {
            guard let cursor = EventTimeline.olderCursor(in: loadedEvents(sessionId)) else { continue }
            olderLoadingSessionIds.insert(sessionId)
            defer { olderLoadingSessionIds.remove(sessionId) }
            do {
                let page = try await client.fetchSessionEvents(
                    endpoint: endpoint, sessionId: sessionId, before: cursor, limit: Self.olderPageSize
                )
                if page.events.count < Self.olderPageSize { olderExhaustedSessionIds.insert(sessionId) }
                if var browsed = browsedEvents[sessionId] {
                    // Same window as live paging: scrolling one long history to
                    // its start must not hold every event it ever had.
                    if upsertMonitorEvents(page.events, into: &browsed, limit: MonitorReducerDefaults.pagedEventLimit) {
                        browsedEvents[sessionId] = browsed
                        arrived = true
                    } else if !page.events.isEmpty {
                        olderExhaustedSessionIds.insert(sessionId)
                        olderCappedSessionIds.insert(sessionId)
                    }
                } else {
                    let before = logEventsBySession[sessionId]?.count ?? 0
                    monitorStore.prependOlder(page.events, sessionId: sessionId)
                    if (logEventsBySession[sessionId]?.count ?? 0) > before {
                        arrived = true
                    } else if !page.events.isEmpty {
                        // The paged window is full (pagedEventLimit): what
                        // came in fell straight off again, so stop offering more.
                        olderExhaustedSessionIds.insert(sessionId)
                        olderCappedSessionIds.insert(sessionId)
                    }
                }
                // Nothing new although the page was full: the rest is what
                // is already loaded.
                if page.events.isEmpty { olderExhaustedSessionIds.insert(sessionId) }
            } catch {
                recordNotice("이전 이벤트를 불러오지 못했습니다: \(error.localizedDescription)")
                olderExhaustedSessionIds.insert(sessionId)
            }
        }
        return arrived
    }

    /// The next page of "지난 기록"; `reset` starts again from the newest.
    ///
    /// A reset keeps the current list until the new page arrives, and keeps
    /// the group the user has open, so its timeline does not go blank.
    func loadHistoryPage(reset: Bool = false) async {
        guard !historyLoading, reset || historyHasMore else { return }
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else { return }
        let openIds = openHistorySessionIds
        historyLoading = true
        defer { historyLoading = false }
        do {
            // The server pages newest first on (updatedAt, sessionId); the
            // last session received is the cursor.
            let cursor = reset ? nil : historyCursor
            let page = try await client.fetchHistory(
                endpoint: endpoint, before: cursor?.updatedAt, beforeId: cursor?.sessionId, limit: Self.historyPageSize
            )
            var list = reset ? [] : browsedHistory
            var known = Set(list.map(\.sessionId))
            let fresh = page.sessions.filter { known.insert($0.sessionId).inserted }
            list.append(contentsOf: fresh)
            if reset {
                list.append(contentsOf: browsedHistory.filter { openIds.contains($0.sessionId) && known.insert($0.sessionId).inserted })
            }
            browsedHistory = list
            if let last = page.sessions.last, let updatedAt = last.updatedAt {
                historyCursor = (updatedAt, last.sessionId)
            } else if reset {
                historyCursor = nil
            }
            // A full page of sessions already listed would page forever.
            historyHasMore = page.hasMore && !fresh.isEmpty
            // At the in-memory cap the list stops growing: paging on would
            // only drop the sessions just fetched.
            if capBrowsedHistory(keeping: openIds) { historyHasMore = false }
            historyError = nil
        } catch {
            historyHasMore = false
            historyError = error.localizedDescription
        }
    }

    /// Pages on until "지난 기록" gains a row (a page can hold only Workers
    /// of groups already listed), at most a few pages per call, so reaching
    /// the last row keeps loading.
    func loadMoreHistoryRows() async {
        let before = historyRows.count
        for _ in 0..<4 {
            await loadHistoryPage()
            guard historyHasMore, historyError == nil, historyRows.count == before else { return }
        }
    }

    /// Sessions of the opened history group: kept through a reset and the cap.
    private var openHistorySessionIds: Set<String> {
        Set(selectedHistoryGroup?.members.map(\.sessionId) ?? [])
    }

    /// Puts sessions that just moved to disk history at the top of the
    /// browsed list, keeping the cursor and the open group. Nothing to do
    /// until the user has looked at history once (the first page loads then).
    private func mergeNewestHistoryPage() async {
        guard !historyLoading, historyCursor != nil || !browsedHistory.isEmpty, let endpoint else { return }
        historyLoading = true
        defer { historyLoading = false }
        guard let page = try? await client.fetchHistory(
            endpoint: endpoint, before: nil, beforeId: nil, limit: Self.historyPageSize
        ) else { return }
        let known = Set(browsedHistory.map(\.sessionId))
        let fresh = page.sessions.filter { !known.contains($0.sessionId) }
        guard !fresh.isEmpty else { return }
        let openIds = openHistorySessionIds
        browsedHistory.insert(contentsOf: fresh, at: 0)
        if historyCursor == nil, let last = page.sessions.last, let updatedAt = last.updatedAt {
            historyCursor = (updatedAt, last.sessionId)
        }
        // Newest sessions came in on top; the oldest fall off the bottom,
        // and paging resumes after the last one kept.
        if capBrowsedHistory(keeping: openIds) {
            if let last = browsedHistory.last(where: { !openIds.contains($0.sessionId) }),
               let updatedAt = last.updatedAt {
                historyCursor = (updatedAt, last.sessionId)
            }
            historyHasMore = true
        }
    }

    /// Keeps "지난 기록" at `browsedHistoryLimit` sessions, newest first,
    /// plus the open group's. Returns whether sessions were dropped.
    @discardableResult
    private func capBrowsedHistory(keeping openIds: Set<String>) -> Bool {
        let limit = MonitorReducerDefaults.browsedHistoryLimit
        guard browsedHistory.count > limit else { return false }
        var kept = Array(browsedHistory.prefix(limit))
        var keptIds = Set(kept.map(\.sessionId))
        kept.append(contentsOf: browsedHistory.dropFirst(limit).filter {
            openIds.contains($0.sessionId) && keptIds.insert($0.sessionId).inserted
        })
        keptIds = Set(kept.map(\.sessionId))
        let dropped = browsedHistory.map(\.sessionId).filter { !keptIds.contains($0) }
        browsedHistory = kept
        for id in dropped { forgetBrowsedEvents(id) }
        return true
    }

    /// Drops one browsed session's events and what was remembered about
    /// loading them.
    private func forgetBrowsedEvents(_ sessionId: String) {
        for scope in browsedScopeSessions.keys { browsedScopeSessions[scope]?.remove(sessionId) }
        if browsedEvents[sessionId] != nil { browsedEvents[sessionId] = nil }
        historyLoadFailedSessionIds.remove(sessionId)
        if logEventsBySession[sessionId] == nil { olderExhaustedSessionIds.remove(sessionId) }
    }

    /// Opens (or closes, with nil) one "지난 기록" group: its Frontdoor and
    /// browsed Workers load together, like one session used to.
    func selectHistoryGroup(_ groupId: String?) async {
        selectedHistoryGroupId = groupId
        selectedHistoryMemberId = nil
        selectedEventId = nil
        guard let groupId, let group = selectedHistoryGroup else { return }
        await loadBrowsedScope("history:\(groupId)", sessionIds: group.members.map(\.sessionId))
    }

    /// Loads the events of a listed Frontdoor's expired Workers (they are
    /// only on disk), when its timeline is on screen.
    func loadExpiredWorkerEvents(frontdoorId: String) async {
        let ids = historyGroups.expiredWorkers[frontdoorId]?.map(\.sessionId) ?? []
        guard !ids.isEmpty else { return }
        await loadBrowsedScope("frontdoor:\(frontdoorId)", sessionIds: ids)
    }

    /// The scope on screen plus the few opened last keep their sessions'
    /// events (`browsedSessionLimit` scopes); an evicted scope's events go
    /// unless another kept scope still uses them.
    private func loadBrowsedScope(_ scope: String, sessionIds: [String]) async {
        browsedScopeSessions[scope, default: []].formUnion(sessionIds)
        for evicted in browsedRecency.touch(scope, pinned: scope) {
            let ids = browsedScopeSessions.removeValue(forKey: evicted) ?? []
            let stillUsed = browsedScopeSessions.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            for id in ids where !stillUsed.contains(id) { forgetBrowsedEvents(id) }
        }
        guard let endpoint else { return }
        var failure: String?
        for sessionId in sessionIds where browsedEvents[sessionId] == nil
            && logEventsBySession[sessionId] == nil
            && !olderLoadingSessionIds.contains(sessionId)
            && !historyLoadFailedSessionIds.contains(sessionId) {
            olderLoadingSessionIds.insert(sessionId)
            defer { olderLoadingSessionIds.remove(sessionId) }
            do {
                let page = try await client.fetchSessionEvents(
                    endpoint: endpoint, sessionId: sessionId, before: nil, limit: Self.olderPageSize
                )
                // Evicted while it loaded: not kept past the cap.
                guard browsedScopeSessions.values.contains(where: { $0.contains(sessionId) }) else { continue }
                browsedEvents[sessionId] = page.events
                if page.events.count < Self.olderPageSize { olderExhaustedSessionIds.insert(sessionId) }
            } catch {
                // Left unloaded, not empty, so 다시 시도 fetches again instead
                // of showing a timeline that is not there.
                historyLoadFailedSessionIds.insert(sessionId)
                failure = error.localizedDescription
            }
        }
        if let failure { recordNotice("기록을 불러오지 못했습니다: \(failure)") }
    }

    /// History sessions whose timeline failed to load; the sequence offers 다시 시도.
    @Published private(set) var historyLoadFailedSessionIds: Set<String> = []

    func retryHistoryGroup() async {
        guard let groupId = selectedHistoryGroupId, let group = selectedHistoryGroup else { return }
        for session in group.members {
            historyLoadFailedSessionIds.remove(session.sessionId)
            olderExhaustedSessionIds.remove(session.sessionId)
        }
        await loadBrowsedScope("history:\(groupId)", sessionIds: group.members.map(\.sessionId))
    }

    func loadHistoryStats() async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else {
            historyStatsError = "Gateway monitor가 아직 연결되지 않았습니다."
            return
        }
        do {
            historyStats = try await client.fetchHistoryStats(endpoint: endpoint)
            historyStatsError = nil
        } catch {
            historyStatsError = error.localizedDescription
        }
    }

    /// Deletes every non-live session from disk and memory. The sidecar also
    /// broadcasts `historyCleared`, which the reducer applies.
    @discardableResult
    func clearHistory() async -> Bool {
        guard !historyClearing, let endpoint else { return false }
        historyClearing = true
        defer { historyClearing = false }
        do {
            historyStats = try await client.clearHistory(endpoint: endpoint)
            historyStatsError = nil
            resetHistoryBrowsing()
            return true
        } catch {
            historyStatsError = error.localizedDescription
            return false
        }
    }

    /// After history was deleted: nothing browsed is valid any more,
    /// including the cursor and an open history session.
    /// Bytes of monitor history on disk, when the sidecar reported them.
    var diskHistoryBytes: Int64? {
        guard let stats = historyStats, stats.path != nil, let bytes = stats.bytes else { return nil }
        return Int64(bytes)
    }

    /// The user turned disk history off and agreed to delete what is there.
    /// Set before saving retention 0: the monitor reconnects without the file
    /// open, and then the file is removed. Cleared again if the save failed.
    func setDiskHistoryDeletionPending(_ pending: Bool) {
        diskHistoryDeletionPending = pending
    }

    private func finishPendingDiskHistoryDeletion() async {
        guard diskHistoryDeletionPending else { return }
        if await clearHistory() { diskHistoryDeletionPending = false }
    }

    private func resetHistoryBrowsing() {
        browsedHistory = []
        browsedEvents = [:]
        browsedRecency.removeAll()
        browsedScopeSessions = [:]
        historyLoadFailedSessionIds = []
        historyCursor = nil
        historyHasMore = true
        historyError = nil
        if selectedHistoryGroupId != nil {
            selectedHistoryGroupId = nil
            selectedHistoryMemberId = nil
            selectedEventId = nil
        }
        let liveIds = Set(sessions.map(\.sessionId))
        olderExhaustedSessionIds = olderExhaustedSessionIds.filter { liveIds.contains($0) }
        olderCappedSessionIds = olderCappedSessionIds.filter { liveIds.contains($0) }
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
                // Nothing chosen is not a "no": onboarding never declines.
                self.pendingHookConsent = self.onboardingMonitoringHooks.isEmpty ? nil : self.onboardingMonitoringHooks
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

    /// The notch chat's way in: the same client and sidecar as the rest of
    /// the app, nil until the sidecar is up.
    func chatConnection() async -> (MonitorClient, MonitorEndpoint)? {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else { return nil }
        return (client, endpoint)
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
            // The old stream must not keep retrying the endpoint that is
            // going away, whether or not the new connection gets that far.
            await self?.client.stop()
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

    /// A new look takes a restart: the pet reads its style at launch.
    func setPetStyle(_ style: PetStyle) {
        guard settings.petStyle != style else { return }
        settings.petStyle = style
        if petRunning { startPet() }
    }

    func restartPet() {
        settings.petEnabled = true
        startPet()
    }

    func resetSettings() {
        settings.reset()
        petStore.stop()
        // Reset turns the pet back on; it should be running, not just ticked.
        if settings.petEnabled { startPet() }
    }

    /// Opens (or brings forward) the settings window on `tab`.
    func openSettings(tab: SettingsTab = .display) {
        settingsWindow.show(model: self, tab: tab)
    }

    func loadAgentCatalog(refresh: Bool = false) async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else {
            agentCatalogStore.setConnectionUnavailable()
            return
        }
        await agentCatalogStore.load(client: client, endpoint: endpoint, refresh: refresh)
    }

    func loadHookStatus() async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else {
            hookError = "Gateway monitor가 아직 연결되지 않았습니다."
            return
        }
        do {
            let status = try await client.fetchHookStatus(endpoint: endpoint)
            // Polled every 15s by the settings tab: an unchanged answer must
            // not republish (and re-render the dashboard).
            if hookStatus != status { hookStatus = status }
            if hookError != nil { hookError = nil }
        } catch {
            let message = error.localizedDescription
            if hookError != message { hookError = message }
        }
    }

    /// After the sidecar connects: apply the onboarding choice, or ask an
    /// existing user once if the hooks have never been agreed to.
    private func reconcileHookConsent() async {
        // The sidecar may still be starting its hook endpoint: a failed read
        // is retried briefly, and an onboarding choice is kept until it lands
        // (the next connection retries it again).
        var status: MonitoringHookStatus?
        for attempt in 0..<5 {
            await loadHookStatus()
            status = hookStatus
            if status?.receiving == true { break }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        guard let status, status.receiving else { return }
        if let chosen = pendingHookConsent {
            if await answerHookConsent(enabled: chosen) { pendingHookConsent = nil }
            return
        }
        if status.consentRequired && !hookConsentAsked {
            hookConsentAsked = true
            hookConsentPresented = true
        }
    }

    /// The user's "yes" to the monitoring-hook question: installs hooks for
    /// the chosen CLIs only. It never removes anything; a CLI left unchecked
    /// keeps whatever it had. An empty choice changes nothing.
    @discardableResult
    func answerHookConsent(enabled providers: Set<String>) async -> Bool {
        guard let endpoint else { return false }
        // A CLI that is not installed was not offered, so it is left out.
        let installed = hookStatus.map { Set($0.targets.filter(\.agentPresent).map(\.provider)) }
            ?? MonitoringConsentChoices.installedCLIs()
        let ordered = Self.frontdoorInstallOrder.filter { providers.contains($0) && installed.contains($0) }
        guard !ordered.isEmpty else { return true }
        hookConsentPresented = false
        do {
            let status = try await client.mutateHooks(endpoint: endpoint, action: "install", providers: ordered, consent: true)
            hookStatus = status
            hookError = status.errors.first
            return true
        } catch {
            hookError = error.localizedDescription
            return false
        }
    }

    /// The sheet's "사용 안 함": removes every AgenLynk hook and remembers the
    /// answer until the consent scope changes. Only the sheet calls this.
    @discardableResult
    func declineHookConsent() async -> Bool {
        guard let endpoint else { return false }
        hookConsentPresented = false
        do {
            let status = try await client.mutateHooks(endpoint: endpoint, action: "uninstall", providers: [], decline: true)
            hookStatus = status
            hookError = status.errors.first
            return true
        } catch {
            hookError = error.localizedDescription
            return false
        }
    }

    /// Turns one CLI's monitoring hook on or off. Off is remembered, so an app
    /// update does not put it back.
    func setHook(_ provider: String, enabled: Bool) async {
        guard hookMutatingProvider == nil, let endpoint else { return }
        hookMutatingProvider = provider
        defer { hookMutatingProvider = nil }
        do {
            // Turning a CLI on from settings is itself the user's consent.
            let status = try await client.mutateHooks(
                endpoint: endpoint,
                action: enabled ? "install" : "uninstall",
                providers: [provider],
                consent: enabled
            )
            hookStatus = status
            hookError = status.errors.first
        } catch {
            hookError = error.localizedDescription
        }
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

    func loadDelegatorSkill() async {
        if endpoint == nil { await ensureStarted() }
        guard let endpoint else { return }
        if let status = try? await client.fetchSkillStatus(endpoint: endpoint), status != delegatorSkill {
            delegatorSkill = status
        }
    }

    /// Puts the shipped skill everywhere it is not current: adds it where it
    /// is missing and replaces copies the user edited (they asked to).
    func updateDelegatorSkill() async {
        guard let endpoint, let pending = delegatorSkill?.pending, !pending.isEmpty, !delegatorSkillUpdating else { return }
        delegatorSkillUpdating = true
        defer { delegatorSkillUpdating = false }
        do {
            delegatorSkill = try await client.syncSkill(
                endpoint: endpoint,
                install: pending.filter { $0.state == "missing" }.map(\.agent),
                force: pending.filter { $0.state == "customized" }.map(\.agent)
            )
            lastNotice = "agent-delegator skill을 업데이트했습니다. 새로 시작하는 세션부터 적용됩니다."
        } catch {
            onboardingError = error.localizedDescription
        }
    }

    /// `installingFrontdoor` while every stale entry is being relinked.
    static let relinkingFrontdoors = "*relink*"

    /// Points every stale control and guide entry, of every CLI, back at
    /// runtime/current in one go — relinking only the control entries used to
    /// leave the guides (and sometimes Codex) on the old version.
    func relinkStaleFrontdoors() {
        guard installingFrontdoor == nil, !onboardingRunning, onboardingInstallLocationReady,
              !staleFrontdoorEntries.isEmpty else { return }
        installingFrontdoor = Self.relinkingFrontdoors
        onboardingError = nil
        lastNotice = nil
        onboardingOutput.removeAll()
        let nodeOverride = settings.nodePath
        let groups = ["control", "guide"].compactMap { kind -> (String, [String])? in
            let targets = Array(Set(staleFrontdoorEntries.filter { $0.entry == kind }.map(\.agent))).sorted()
            return targets.isEmpty ? nil : (kind, targets)
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.installingFrontdoor = nil }
            do {
                for (kind, targets) in groups {
                    let result = try await self.installer.relink(kind: kind, targets: targets, nodeOverride: nodeOverride) { line in
                        Task { @MainActor [weak self] in self?.appendOnboardingOutput(line) }
                    }
                    guard result.ok else {
                        self.onboardingError = result.message
                        await self.loadInstalledFrontdoors()
                        return
                    }
                }
                self.lastNotice = "MCP 항목을 현재 Gateway로 다시 연결했습니다. 각 CLI를 다시 시작하면 적용됩니다."
                await self.loadInstalledFrontdoors()
            } catch {
                self.onboardingError = error.localizedDescription
                await self.loadInstalledFrontdoors()
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
            if installedFrontdoors != snapshot.installed { installedFrontdoors = snapshot.installed }
            if guideOnlyFrontdoors != snapshot.guideOnly { guideOnlyFrontdoors = snapshot.guideOnly }
            if primaryFrontdoor != snapshot.primary { primaryFrontdoor = snapshot.primary }
            if staleFrontdoorEntries != snapshot.stale { staleFrontdoorEntries = snapshot.stale }
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
        // Only a hint for the cleanup button; a failed preview hides it.
        runtimePrunePreview = try? await runtimeManager.prune(dryRun: true)
    }

    /// Removes installed runtime versions that are neither current nor the
    /// rollback target and that nothing still launches from. Each version
    /// carries its own Node and Gateway (hundreds of MB), and nothing else
    /// ever removes them.
    func pruneRuntimeVersions() async {
        guard !runtimeBusy else { return }
        runtimeBusy = true
        defer { runtimeBusy = false }
        runtimeError = nil
        runtimeNotice = nil
        do {
            let result = try await runtimeManager.prune(dryRun: false)
            runtimeNotice = result.removed.isEmpty
                ? "정리할 런타임이 없습니다."
                : "런타임 \(result.removed.count)개를 삭제해 \(result.freedText)를 확보했습니다."
        } catch {
            runtimeError = error.localizedDescription
        }
        runtimeInspection = (try? await runtimeManager.inspect()) ?? runtimeInspection
        runtimePrunePreview = try? await runtimeManager.prune(dryRun: true)
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
            runtimeNotice = "이전 런타임으로 되돌렸습니다. 이 버전에 고정되며, Gateway를 다시 시작하면 적용됩니다."
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
        // Saving a monitor setting just reconnected the monitor; wait for it
        // instead of failing a restart the user asked for in the same click.
        if endpoint == nil { await ensureStarted() }
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

    /// Settings the sidecar reads only at start, so saving one reconnects
    /// the monitor (the Gateway and agents keep running).
    static let monitorConfigOptionIds: Set<String> = [
        "localScannerEnabled", "localScanIntervalMs", "localDiscoveryIntervalMs", "localTranscriptWindowMs",
        "localSessionRetentionMs", "monitorHistoryRetentionMs", "localTranscriptRecordLimit"
    ]

    func isMonitorConfigOption(_ id: String) -> Bool {
        if Self.monitorConfigOptionIds.contains(id) { return true }
        return gatewayConfigOptions.first { $0.id == id }?.group == "monitor"
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
            await reconcileHookConsent()
            await finishPendingDiskHistoryDeletion()
            guard connectionIsCurrent(generation) else { return }
            await client.startStream(endpoint: endpoint, onMessage: { [weak self] value in
                guard let self, self.connectionIsCurrent(generation) else { return }
                self.apply(streamMessage: value)
            }, onState: { [weak self] connected, error in
                guard let self, self.connectionIsCurrent(generation) else { return }
                let reconnected = connected && !self.sidecarStreamConnected
                self.sidecarStreamConnected = connected
                if connected { self.notchChat.streamConnected() }
                // State frames carry only what changed; a stream that just
                // (re)connected catches up from one snapshot instead.
                if reconnected { self.reconcileNow(endpoint: endpoint, generation: generation) }
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
            // Failed before startStream: no stream may keep polling a dead
            // endpoint behind the disconnected phase.
            await client.stop()
            guard connectionIsCurrent(generation) else { return }
            monitorStore.setConnection(connected: false, streaming: false)
            sidecarStreamConnected = false
            phase = .disconnected(describeConnectFailure(error))
            // Nothing else retries a failed start: no stream, no reconciliation.
            // A sidecar that came up slowly once would otherwise leave the app
            // disconnected until the person pressed reconnect.
            if sidecarRestartAttempts < Self.maxAutomaticReconnects {
                scheduleReconnect(generation: generation)
            }
        }
    }

    private static let maxAutomaticReconnects = 8

    private func reconcileNow(endpoint: MonitorEndpoint, generation: Int) {
        Task { [weak self] in
            // A frame the stream applies while the snapshot is on its way is
            // newer than the snapshot: try again rather than roll it back.
            for _ in 0..<3 {
                guard let self, self.connectionIsCurrent(generation) else { return }
                guard let snapshot = try? await self.client.fetchSnapshot(endpoint: endpoint) else { return }
                guard self.connectionIsCurrent(generation) else { return }
                if self.monitorStore.isCurrent(snapshot) {
                    self.apply(snapshot)
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func startReconciliation(endpoint: MonitorEndpoint, generation: Int) {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                // A live stream already carries every change (and a reconnect
                // fetches a snapshot): this is only a safety net and the
                // sidecar's liveness check then. Without a stream it is how
                // the app keeps up, so it runs often.
                let streaming = self?.sidecarStreamConnected ?? false
                try? await Task.sleep(nanoseconds: streaming ? 60_000_000_000 : 10_000_000_000)
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
                    // Built before a frame the stream already applied: older
                    // than what is on screen. One built after it is applied
                    // however busy the stream is.
                    if !self.monitorStore.isCurrent(snapshot) {
                        self.sidecarRestartAttempts = 0
                        continue
                    }
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
        guard connectionIsCurrent(generation), !(await sidecar.isRunning()) else { return }
        scheduleReconnect(generation: generation)
    }

    /// Reconnects after a backoff that grows with each attempt (0.5 s .. 8 s).
    private func scheduleReconnect(generation: Int) {
        guard connectionIsCurrent(generation), sidecarRestartTask == nil else { return }
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
        if let revision = message.int("revision") { monitorStore.noteStreamRevision(revision) }
        switch kind {
        case "reply_slot", "reply_slot_closed":
            // A Frontdoor's Stop the notch may answer; not monitor state.
            notchChat.handleReplyMessage(kind: kind, message: message)
        case "events":
            // Changed canonical events, upserted by id (Monitor API v2).
            monitorStore.applyEventsMessage(message)
        case "state":
            let effect = monitorStore.applyStateMessage(message)
            if message.bool("historyCleared") == true {
                resetHistoryBrowsing()
                Task { await loadHistoryStats() }
            }
            if monitorStore.state.connected { updateConnectionPhase() }
            else if let error = effect.disconnectedError {
                let nextPhase = ConnectionPhase.disconnected(error)
                if phase != nextPhase {
                    phase = nextPhase
                    recordNotice(error)
                }
            }
            if let notice = effect.pausedSubscriptionNotice { recordNotice(notice) }
            // A state frame that changed nothing (a keep-alive) has nothing
            // to reconcile or hand to the Pet.
            if effect.stateChanged {
                reconcileSelections()
                syncPetSnapshot()
            }
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
            projection: PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox, nickname: petNickname),
            style: settings.petStyle,
            enabled: { [weak self] in self?.settings.petEnabled == true }
        )
    }

    private func syncPetSnapshot() {
        // Nothing to feed: skip building the projection on every frame.
        guard settings.petEnabled, petRunning else { return }
        petStore.sync(
            projection: PetActivityProjection.make(sessions: realtimeSessions, inbox: realtimeInbox, nickname: petNickname),
            enabled: settings.petEnabled
        )
    }

    private func reconcileSelections() {
        // Reconcile against the SAME merged list the sidebar shows. Checking the
        // live-only `frontdoorSessions` here reassigned selectedFrontdoorId every
        // time a Frontdoor briefly left the live list, and DashboardView's
        // onChange(selectedFrontdoorId) then cleared the selected event — the
        // reported "clicking an event, it deselects on update" bug.
        // The merged log's Frontdoors are exactly live + history minus
        // internal reviews, already built (and cached) for the sidebar.
        let next = MonitorSelection.reconcile(
            selectedFrontdoorId: selectedFrontdoorId,
            selectedEventId: selectedEventId,
            frontdoors: logFrontdoorSessions,
            liveEvents: eventsBySession,
            historyEvents: historyEventsBySession
        )
        if selectedFrontdoorId != next.frontdoorId { selectedFrontdoorId = next.frontdoorId }
        // A browsed event (an opened history group's, or an expired Worker's
        // under its Frontdoor) is not in the live/history buckets the
        // reconciliation knows; it stays selected while it is loaded.
        let browsedSelection = selectedEventId.map { MonitorSelection.contains($0, in: browsedEvents) } ?? false
        if !browsedSelection, selectedEventId != next.eventId { selectedEventId = next.eventId }
        if let selectedSessionId,
           !visibleLogSessions.contains(where: { $0.sessionId == selectedSessionId }),
           !(selectedFrontdoor?.members.contains { $0.sessionId == selectedSessionId } ?? false) {
            self.selectedSessionId = selectedFrontdoor?.root?.sessionId ?? selectedFrontdoor?.workers.first?.sessionId
        }
    }

    private func eventIsVisible(_ event: MonitorEvent) -> Bool {
        if !settings.showThoughts, event.kind == "agent_thought" { return false }
        if !settings.showToolEvents, event.kind == "tool_call" { return false }
        return true
    }

}
