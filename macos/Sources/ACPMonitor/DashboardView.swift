import ACPShared
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showForceRepairConfirmation = false

    var body: some View {
        Group {
            switch model.startupPhase {
            case .checking, .provisioningRuntime:
                ProgressView("Gateway runtime 준비 중…").frame(minWidth: 560, minHeight: 420)
            case let .runtimeError(message):
                runtimeErrorView(message)
            case .onboarding:
                OnboardingView()
            case .ready:
                dashboardContent
            }
        }
        .task { model.startIfNeeded() }
        .sheet(isPresented: $model.hookConsentPresented) {
            MonitoringConsentSheet()
        }
        .confirmationDialog(
            "손상된 Gateway runtime을 교체하시겠습니까?",
            isPresented: $showForceRepairConfirmation,
            titleVisibility: .visible
        ) {
            Button("bundled runtime으로 강제 복구", role: .destructive) {
                model.forceRuntimeRepair()
            }
        } message: {
            Text("검증 가능한 기존 runtime을 찾지 못한 경우에만 사용하세요. 실행 중인 Gateway 작업이 있다면 먼저 종료해야 합니다.")
        }
    }

    private func runtimeErrorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ACPLogoMark().frame(width: 40, height: 40)
            Text("Gateway runtime 설치 실패").font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.red).font(.callout)
            HStack {
                Button("다시 시도") { model.retryRuntimeProvisioning() }
                    .buttonStyle(.borderedProminent)
                Button("손상된 runtime 복구…", role: .destructive) {
                    showForceRepairConfirmation = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
    }

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            connectionBar
            metricStrip
            Divider()
            // The sequence diagram is the reason this window is open, so the
            // side columns default to just enough width for their own rows and
            // the center takes the rest. Both keep their old max widths, so a
            // divider drag still restores the roomier layout.
            GeometryReader { proxy in
                let layout = DashboardPanelLayout(
                    width: proxy.size.width,
                    wantsSessions: settings.showSessionColumn,
                    wantsInspector: settings.showInspectorColumn,
                    forceSessions: forceSessionColumn,
                    forceInspector: forceInspectorColumn
                )
                HSplitView {
                    if layout.showsSessions {
                        sessionColumn
                            .frame(minWidth: 170, idealWidth: 190, maxWidth: 340)
                    }
                    eventColumn
                        .frame(minWidth: 420, idealWidth: 820)
                    if layout.showsInspector {
                        operationsColumn
                            .frame(minWidth: 220, idealWidth: 240, maxWidth: 440)
                    }
                }
                .onAppear { panelLayout = layout }
                .onChange(of: layout) { _, next in
                    panelLayout = next
                    // A forced panel lasts until the window has room again.
                    if next.fitsSessions { forceSessionColumn = false }
                    if next.fitsInspector { forceInspectorColumn = false }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ACPApplicationIconUpdater().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    togglePanel(sessions: true)
                } label: {
                    Label("세션 목록", systemImage: "sidebar.left")
                }
                .help(panelHelp(sessions: true))
                .accessibilityLabel(panelHelp(sessions: true))
            }
            ToolbarItemGroup {
                Button {
                    togglePanel(sessions: false)
                } label: {
                    Label("인스펙터", systemImage: "sidebar.right")
                }
                .help(panelHelp(sessions: false))
                .accessibilityLabel(panelHelp(sessions: false))
                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                }
                .help("설정")
                // Live monitoring now lives in the menu-bar popover; a second
                // entry point here was the same window twice.
                Button("모니터 다시 연결", systemImage: "arrow.clockwise") { model.reconnect() }
                    .help("모니터 다시 연결")
            }
        }
        .onChange(of: model.selectedFrontdoorId) { _, _ in
            // A new scope opens at its newest event, following.
            settings.followLatestEvent = true
            guard model.selectedHistorySessionId == nil else { return }
            let members = Set(model.selectedFrontdoor?.members.map(\.sessionId) ?? [])
            // An event of the new scope (it was just clicked) stays selected.
            if !(model.selectedEvent.map { members.contains($0.sessionId) } ?? false) {
                model.selectedEventId = nil
            }
            if model.selectedSession?.openerInstanceId != model.selectedFrontdoorId {
                // A member waiting on the person is what the selection is for.
                model.selectedSessionId = model.selectedFrontdoor?.preferredSession?.sessionId
            }
        }
        .onChange(of: model.selectedSessionId) { _, _ in
            guard model.selectedHistorySessionId == nil else { return }
            // Selecting a session (a lane, or an event's session) keeps the
            // selected event; the scope follows the session's Frontdoor.
            if let openerInstanceId = model.selectedSession?.openerInstanceId,
               openerInstanceId != model.selectedFrontdoorId {
                model.selectedFrontdoorId = openerInstanceId
            }
        }
    }

    @State private var showNoticeLog = false
    @State private var showGatewayInfo = false
    @ObservedObject private var disclosures = InspectorDisclosures.shared
    @State private var panelLayout = DashboardPanelLayout(width: 1200, wantsSessions: true, wantsInspector: true)
    @State private var forceSessionColumn = false
    @State private var forceInspectorColumn = false

    /// A panel folded away by a narrow window opens on demand; otherwise the
    /// button is the user's show/hide preference, which persists. Forcing one
    /// panel open clears the other's force: where both do not fit, the one
    /// asked for last wins instead of the two fighting over the width.
    private func togglePanel(sessions: Bool) {
        if sessions {
            if panelLayout.showsSessions {
                forceSessionColumn = false
                settings.showSessionColumn = false
            } else {
                // Asking for a panel opens it now, even where the width
                // would fold it.
                settings.showSessionColumn = true
                if !panelLayout.fitsSessions || (panelLayout.showsInspector && !panelLayout.fitsBoth) {
                    forceSessionColumn = true
                    forceInspectorColumn = false
                }
            }
        } else {
            if panelLayout.showsInspector {
                forceInspectorColumn = false
                settings.showInspectorColumn = false
            } else {
                settings.showInspectorColumn = true
                if !panelLayout.fitsInspector || (panelLayout.showsSessions && !panelLayout.fitsBoth) {
                    forceInspectorColumn = true
                    forceSessionColumn = false
                }
            }
        }
    }

    /// The tooltip says what the click will do, including the panel it
    /// folds to make room.
    private func panelHelp(sessions: Bool) -> String {
        let name = sessions ? "세션 목록" : "인스펙터"
        let other = sessions ? "인스펙터" : "세션 목록"
        let shown = sessions ? panelLayout.showsSessions : panelLayout.showsInspector
        let otherShown = sessions ? panelLayout.showsInspector : panelLayout.showsSessions
        if shown { return "\(name) 숨기기" }
        if otherShown && !panelLayout.fitsBoth { return "\(withObjectParticle(other)) 접고 \(name) 펼치기" }
        let wanted = sessions ? settings.showSessionColumn : settings.showInspectorColumn
        let fits = sessions ? panelLayout.fitsSessions : panelLayout.fitsInspector
        if wanted && !fits { return "창이 좁아 \(withObjectParticle(name)) 접었습니다 · 누르면 펼치기" }
        return "\(name) 보이기"
    }

    private var connectionBar: some View {
        HStack(spacing: 9) {
            ACPLogoMark().frame(width: 27, height: 27)
            Divider().frame(height: 22)
            Circle().fill(connectionColor).frame(width: 9, height: 9)
            Text(connectionText).font(.callout.weight(.medium))
            // Notices used to flash by too fast to read; the bar keeps showing
            // the newest one, and clicking it (or the bell) opens the retained
            // log with timestamps.
            if let notice = model.lastNotice {
                Button { showNoticeLog = true } label: {
                    Text(notice).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("최근 알림·오류 \(model.noticeLog.count)건 보기")
            }
            if !model.noticeLog.isEmpty {
                Button { showNoticeLog = true } label: {
                    Label("\(model.noticeLog.count)", systemImage: "bell.badge")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("최근 알림·오류 \(model.noticeLog.count)건 보기")
                .accessibilityLabel("최근 알림·오류 \(model.noticeLog.count)건 보기")
                .popover(isPresented: $showNoticeLog, arrowEdge: .bottom) {
                    NoticeLogView(entries: model.noticeLog)
                }
            }
            Spacer()
            // Version, build and the retained-event count are reference, not
            // status: one ⓘ keeps them reachable without crowding the bar.
            Button { showGatewayInfo = true } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Gateway 버전 · 보관 이벤트 보기")
            .accessibilityLabel("Gateway 버전 · 보관 이벤트 보기")
            .popover(isPresented: $showGatewayInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Gateway", value: model.gatewayVersion)
                    LabeledContent("build") {
                        Text(model.gatewayBuild).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent("보관 이벤트", value: model.totalEventCount.formatted())
                }
                .font(.caption)
                .padding(12)
                .frame(width: 260)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private var metricStrip: some View {
        HStack(spacing: 12) {
            MetricCard(title: "활성 Frontdoor", value: "\(model.activeFrontdoors.count)", symbol: "bolt.fill", color: statusColor("running"))
            MetricCard(
                title: "실행 중 세션 · Gateway \(model.realtimeACPCount) / 로컬 \(model.realtimeLocalCount)",
                value: "\(model.realtimeSessions.count)",
                symbol: "person.2.wave.2",
                color: statusColor("running")
            )
            MetricCard(title: "미응답 요청", value: "\(model.pendingInbox.count)", symbol: "exclamationmark.bubble", color: statusColor("waiting_permission"))
        }
        .padding(12)
    }

    private var sessionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Narrow column: the title yields first, the filter toggle keeps
            // its intrinsic width so its checkbox never clips.
            HStack(spacing: 6) {
                Label("Frontdoor 세션", systemImage: "rectangle.stack")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Toggle("활성만", isOn: $settings.activeOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .fixedSize()
                    .help("실행 중이거나 대기 유지 시간 안에 있는 세션만 보입니다")
            }
            .padding(10)
            Divider()
            List(selection: sidebarSelection) {
                ForEach(model.visibleFrontdoors) { frontdoor in
                    FrontdoorRow(frontdoor: frontdoor)
                        .tag(frontdoor.id)
                }
                frontdoorListFooter
                historySection
            }
            .listStyle(.sidebar)
        }
    }

    private static let historyTagPrefix = "history:"

    /// Why the Frontdoor list is short or empty, and the way back.
    @ViewBuilder private var frontdoorListFooter: some View {
        let hidden = settings.activeOnly
            ? model.logFrontdoorSessions.count - model.visibleFrontdoors.count
            : 0
        if model.visibleFrontdoors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if hidden > 0 {
                    Text("진행 중인 Frontdoor가 없습니다").font(.caption.weight(.medium))
                } else {
                    Text("실행 중인 Frontdoor 없음 · 터미널에서 claude/codex/grok을 실행하면 표시됩니다")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.secondary)
            .selectionDisabled()
        }
        if hidden > 0 {
            HStack(spacing: 4) {
                Text("활성만 보기로 \(hidden)개 숨김")
                Button("전체 보기") { settings.activeOnly = false }
                    .buttonStyle(.borderless)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .selectionDisabled()
        }
    }

    /// One selection for both sidebar sections: a Frontdoor id, or a
    /// "history:" tag for a browsed history session. Only a click goes
    /// through here, so the reconciliation that re-picks a Frontdoor on
    /// updates never closes an opened history session.
    private var sidebarSelection: Binding<String?> {
        Binding(
            get: {
                if let id = model.selectedHistorySessionId { return Self.historyTagPrefix + id }
                return model.selectedFrontdoorId
            },
            set: { value in
                if let value, value.hasPrefix(Self.historyTagPrefix) {
                    let sessionId = String(value.dropFirst(Self.historyTagPrefix.count))
                    settings.followLatestEvent = true
                    Task { await model.selectHistorySession(sessionId) }
                } else {
                    if model.selectedHistorySessionId != nil {
                        Task { await model.selectHistorySession(nil) }
                        settings.followLatestEvent = true
                    }
                    model.selectedFrontdoorId = value
                }
            }
        )
    }

    /// Older sessions from the on-disk history, paged in as the list's end
    /// scrolls into view.
    private var historySection: some View {
        Section {
            ForEach(model.browsableHistory) { session in
                HistorySessionRow(session: session)
                    .tag(Self.historyTagPrefix + session.sessionId)
                    .onAppear {
                        guard session.sessionId == model.browsableHistory.last?.sessionId else { return }
                        Task { await model.loadHistoryPage() }
                    }
            }
            // The end of the list: reaching it loads the next page.
            HStack(spacing: 6) {
                if model.historyLoading {
                    ProgressView().controlSize(.mini)
                    Text("불러오는 중…")
                } else if let error = model.historyError {
                    Label(error, systemImage: "exclamationmark.triangle").lineLimit(2)
                } else if model.historyHasMore {
                    Button("더 불러오기") { Task { await model.loadHistoryPage() } }
                        .buttonStyle(.borderless)
                } else if model.browsableHistory.isEmpty {
                    Text("지난 기록 없음")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .onAppear { Task { await model.loadHistoryPage() } }
        } header: {
            HStack(spacing: 4) {
                Text("지난 기록")
                Spacer(minLength: 0)
                Button {
                    Task { await model.loadHistoryPage(reset: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("지난 기록 새로 고침")
                .accessibilityLabel("지난 기록 새로 고침")
            }
        }
    }

    /// The sessions the sequence shows: the opened history session, else the
    /// selected Frontdoor's members, else every visible session.
    private var sequenceSessions: [GatewaySession] {
        if let history = model.selectedHistorySession { return [history] }
        return model.selectedFrontdoor?.members ?? model.visibleLogSessions
    }

    private var sequenceScopeKey: String {
        if let id = model.selectedHistorySessionId { return "history:\(id)" }
        return model.selectedFrontdoorId ?? "all"
    }

    private var eventColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(
                    model.selectedHistorySessionId != nil ? "지난 기록 이벤트 시퀀스"
                        : model.selectedFrontdoorId == nil ? "전체 이벤트 시퀀스" : "Frontdoor 이벤트 시퀀스",
                    systemImage: "timeline.selection"
                )
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            let contextSession = model.selectedHistorySession ?? model.selectedSession
            SequenceSelectionContext(
                frontdoor: model.selectedHistorySessionId == nil ? model.selectedFrontdoor : nil,
                session: contextSession,
                activity: contextSession.map { sessionActivity(for: $0) },
                inHistory: contextSession.map { model.showsAsHistory($0) } ?? false
            )
            Divider()
            let sessionIds = sequenceSessions.map(\.sessionId)
            EventSequenceView(
                sessions: sequenceSessions,
                events: model.selectedEvents,
                selectedSessionId: $model.selectedSessionId,
                selectedEventId: $model.selectedEventId,
                followLatestEvent: $settings.followLatestEvent,
                canLoadOlder: model.mayHaveOlderEvents(in: sessionIds),
                loadingOlder: !model.olderLoadingSessionIds.isDisjoint(with: sessionIds),
                olderCapped: !model.olderCappedSessionIds.isDisjoint(with: sessionIds),
                loadOlder: { await model.loadOlderEvents(sessionIds: sessionIds) },
                emptyState: sequenceEmptyState,
                eventsRevision: model.eventsRevision
            )
            // A new scope is a new timeline: fresh scroll position (newest at
            // the bottom) and no groups left expanded from the previous one.
            .id(sequenceScopeKey)
        }
    }

    /// What an empty sequence should say: a history session still loading or
    /// failed, a source that cannot show a timeline, or plain "nothing yet".
    private var sequenceEmptyState: SequenceEmptyState {
        if let history = model.selectedHistorySession {
            let id = history.sessionId
            if model.historyLoadFailedSessionIds.contains(id) {
                return SequenceEmptyState(
                    title: "기록을 불러오지 못했습니다",
                    symbol: "exclamationmark.triangle",
                    description: "최근 알림에서 원인을 확인하세요.",
                    retry: { Task { await model.retryHistorySession(id) } }
                )
            }
            if model.browsedEvents[id] == nil {
                return SequenceEmptyState(title: "기록 불러오는 중…", loading: true)
            }
        }
        let sessions = sequenceSessions
        if !sessions.isEmpty, !sessions.contains(where: \.canShowTimeline) {
            return SequenceEmptyState(
                title: "이 소스에서는 이벤트 타임라인을 볼 수 없습니다",
                symbol: "eye.slash",
                description: "상태만 받는 세션입니다. hook을 켜거나 대화 기록을 읽을 수 있으면 표시됩니다."
            )
        }
        return SequenceEmptyState()
    }

    /// What the clicked agent is doing right now, read from the newest event
    /// of its session — the selection context leads with this instead of a bare
    /// status word, because "무엇을 하는 중인가" is the question the top strip is
    /// there to answer.
    private func sessionActivity(for session: GatewaySession) -> SessionActivity {
        let events = model.browsedEvents[session.sessionId]
            ?? model.logEventsBySession[session.sessionId]
            ?? []
        // Buckets are kept in within-session order, so the newest event is
        // the last one, and only the trailing run of tool calls is scanned.
        let latest = events.last
        let toolRun = EventTimeline.trailingToolGroup(events)
        let detail: String? = {
            guard let latest else { return session.title }
            // A run of tool calls reads as the run ("도구 12개 · 실행 중: …");
            // a single call by its compact header, never by its output.
            if let toolRun { return toolRun.summary(titleLimit: 40) }
            if latest.kind == "tool_call" { return latest.compactToolTitle(limit: 60) }
            if let state = latest.requestStateLabel { return [state, latest.title].compactMap { $0 }.joined(separator: " · ") }
            return latest.body ?? latest.title ?? session.title
        }()
        let headline = sessionActivityHeadline(status: session.status, isActive: session.isActive, latestKind: latest?.kind)
        let symbol: String
        let color: Color
        if session.isWaitingForUser || !session.isActive || session.status == "cancelling" {
            symbol = sessionStatusSymbol(session.status)
            color = statusColor(session.status)
        } else {
            switch latest?.kind {
            case "agent_thought": symbol = "brain.head.profile"
            case "agent_message": symbol = "text.bubble.fill"
            case "tool_call": symbol = "wrench.and.screwdriver.fill"
            default: symbol = "bolt.fill"
            }
            color = statusColor("running")
        }
        return SessionActivity(symbol: symbol, color: color, headline: headline, detail: detail)
    }

    /// The session the inspector's usage block describes: the opened
    /// history session, else the selected one.
    private var inspectorSession: GatewaySession? {
        model.selectedHistorySession ?? model.selectedSession
    }

    private var operationsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The selected session's usage and forecast lead, with or
                // without a selected event: "how far along is this turn" is
                // what a Frontdoor click is asking.
                if let session = inspectorSession {
                    InspectorSection(title: "선택한 세션", symbol: "rectangle.and.hand.point.up.left") {
                        HStack(spacing: 5) {
                            ProviderIcon(provider: session.provider, size: 14)
                            Text(settings.sessionName(session)).lineLimit(1)
                                .help("세션 id: \(session.sessionId)")
                        }
                        if let model = session.model {
                            LabeledContent("모델", value: model)
                        }
                        LabeledContent("역할", value: session.isFrontdoorRecord ? "Frontdoor" : "Worker")
                        SessionCapabilityBadges(session: session, inHistory: model.showsAsHistory(session))
                        let forecast = UsageForecast(session: session)
                        if session.usage != nil || forecast.currentTurnRunning {
                            SessionUsageView(usage: session.usage, partial: session.usagePartial, forecast: forecast)
                        }
                    }
                }
                InspectorSection(title: "선택 이벤트", symbol: "doc.text.magnifyingglass") {
                    if let event = model.selectedEvent {
                        let eventSession = model.knownSession(event.sessionId)
                        if let eventSession, let selected = inspectorSession, selected.sessionId != eventSession.sessionId {
                            // A lane click moved the session but kept the
                            // event; say so instead of mixing the two.
                            Label("이 이벤트는 \(settings.sessionName(eventSession))의 것입니다.", systemImage: "arrow.left.arrow.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let eventSession {
                            LabeledContent("세션") {
                                HStack(spacing: 5) {
                                    ProviderIcon(provider: eventSession.provider, size: 14)
                                    Text(settings.sessionName(eventSession)).lineLimit(1)
                                }
                            }
                        }
                        LabeledContent("이벤트", value: event.kindLabel)
                        if let state = event.stateLabel {
                            LabeledContent("상태", value: state)
                        }
                        LabeledContent("시간", value: shortTime(event.timestamp))
                            .lineLimit(1)
                        Divider()
                        // Same body-first treatment as the session detail pane;
                        // this column is an inspector, not an export, so the
                        // JSON only has to stay reachable, not lead.
                        EventBodyView(
                            event: event,
                            characterLimit: 4_000,
                            bodyFont: .caption
                        )
                    } else {
                        EmptyLabel("이벤트를 선택하세요")
                    }
                }
                // Reference sections start folded so the event and usage stay
                // on screen; each remembers its state while the app runs.
                InspectorDisclosure(title: "Gateway 상태", symbol: "network", isExpanded: $disclosures.gateway) {
                    LabeledContent("연결", value: model.connectionDetail)
                    LabeledContent("저장소", value: model.persistenceHealthy.map { $0 ? "정상" : "오류" } ?? "—")
                    LabeledContent("감지된 CLI", value: model.detectedProviderCount.formatted())
                }
                InspectorDisclosure(title: "미응답 요청 \(model.inbox.count)", symbol: "tray.full", isExpanded: $disclosures.inbox) {
                    if model.inbox.isEmpty { EmptyLabel("요청 없음") }
                    ForEach(model.inbox) { RecordRow(record: $0) }
                }
                InspectorDisclosure(title: "태스크 \(model.tasks.count)", symbol: "checklist", isExpanded: $disclosures.tasks) {
                    if model.tasks.isEmpty { EmptyLabel("태스크 없음") }
                    ForEach(model.tasks) { RecordRow(record: $0) }
                }
            }
            .padding(14)
            // Bind the scroll content to the column's width so the vertical
            // scrollbar rides the column's trailing edge instead of the edge of
            // some wider child, and so the column can actually shrink when the
            // window does.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionColor: Color {
        if case .connected = model.phase { return .green }
        if case .degraded = model.phase { return .orange }
        if case .starting = model.phase { return .secondary }
        return .red
    }

    private var connectionText: String {
        switch model.phase {
        case .idle: "대기 중"
        case .starting: "모니터 시작 중…"
        case .connected: "Gateway 연결됨"
        case let .degraded(message): message
        case let .disconnected(message): message
        }
    }
}

struct SessionActivity {
    let symbol: String
    let color: Color
    let headline: String
    let detail: String?
}

private struct SequenceSelectionContext: View {
    @EnvironmentObject private var settings: AppSettings
    let frontdoor: FrontdoorSession?
    let session: GatewaySession?
    var activity: SessionActivity? = nil
    var inHistory = false
    @State private var editingName = false
    @State private var nameDraft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let frontdoor {
                VStack(alignment: .leading, spacing: 5) {
                    // The name is auto (working folder) but a person can rename
                    // it here and it persists; the pencil enters an inline
                    // editor, an empty save reverts to the auto name.
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack").font(.caption).foregroundStyle(.secondary)
                        if editingName {
                            TextField("이름", text: $nameDraft, onCommit: { commitName(frontdoor) })
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                                .frame(maxWidth: 180)
                            Button("저장") { commitName(frontdoor) }.buttonStyle(.borderless)
                            Button("취소") { editingName = false }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        } else {
                            Text(settings.frontdoorName(id: frontdoor.id, auto: frontdoor.displayName))
                                .font(.callout.weight(.semibold)).lineLimit(1)
                            Button {
                                nameDraft = settings.frontdoorName(id: frontdoor.id, auto: frontdoor.displayName)
                                editingName = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("이름 변경")
                            .accessibilityLabel("이름 변경")
                            if settings.hasFrontdoorNickname(id: frontdoor.id) {
                                Button {
                                    settings.setFrontdoorName(nil, id: frontdoor.id)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("자동 이름으로 되돌리기")
                                .accessibilityLabel("자동 이름으로 되돌리기")
                            }
                        }
                    }
                    .onChange(of: frontdoor.id) { _, _ in editingName = false }
                    // Narrow widths drop the lower-priority pills instead of
                    // wrapping them onto a second line.
                    ViewThatFits(in: .horizontal) {
                        frontdoorPills(frontdoor, level: 3)
                        frontdoorPills(frontdoor, level: 2)
                        frontdoorPills(frontdoor, level: 1)
                        frontdoorPills(frontdoor, level: 0)
                    }
                    if let task = frontdoor.latestTask, task != frontdoor.displayName {
                        Text(task).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if frontdoor != nil, session != nil {
                Divider().frame(height: 68)
            }

            if let session {
                // Identity + what it is doing. The log text does NOT stack
                // under the headline here; it moves to its own column on the
                // right so this block stays the same height as the Frontdoor
                // block beside it.
                VStack(alignment: .leading, spacing: 5) {
                    Label("선택한 세션", systemImage: "rectangle.and.hand.point.up.left")
                        .font(.caption.weight(.semibold))
                    if let activity {
                        HStack(spacing: 6) {
                            Image(systemName: activity.symbol)
                                .foregroundStyle(activity.color)
                                .font(.callout)
                            Text(activity.headline)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(activity.color)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 6) {
                        // The LOCAL/ACP source is not something a reader acts
                        // on; role and model are.
                        ContextPill(text: session.isFrontdoorRecord ? "Frontdoor" : "Worker", color: .secondary)
                        ProviderIcon(provider: session.provider, size: 14)
                        if let model = session.model {
                            Text(model)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                        }
                    }
                    SessionCapabilityBadges(session: session, inHistory: inHistory)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The activity log fills the right-hand empty space rather than
                // pushing the agent block taller. Multi-line here is fine — it
                // is the widest column, and the whole strip is sized to it.
                if let detail = activity?.detail, !detail.isEmpty {
                    Divider().frame(height: 68)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("현재 활동 로그", systemImage: "text.alignleft")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if frontdoor == nil, session == nil {
                Label("왼쪽 Frontdoor 또는 시퀀스의 세션을 선택하면 지금 무엇을 하는지 표시됩니다", systemImage: "cursorarrow.click")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The Frontdoor's pills, most important first; `level` keeps that many
    /// optional pills after the status (3 = all).
    private func frontdoorPills(_ frontdoor: FrontdoorSession, level: Int) -> some View {
        // The whole work: the Frontdoor and every worker it opened.
        let work = WorkUsage(sessions: frontdoor.members)
        return HStack(spacing: 6) {
            ProviderIcon(provider: frontdoor.provider, size: 16)
            ContextPill(text: frontdoor.statusText, color: statusColor(frontdoor.statusKey))
            if let current = work.currentTurnText {
                ContextPill(text: current, color: .secondary)
                    .help(ifPresent: work.currentTurnHelp)
            }
            if level >= 1 {
                ContextPill(text: "Worker \(frontdoor.workers.count)", color: .secondary)
            }
            if level >= 2, let total = work.totalTokens {
                ContextPill(text: "작업 토큰 \(formatTokenCount(total))", color: .secondary)
                    .help("이 Frontdoor와 Worker들의 세션 누적 토큰 합계입니다(입력은 cache 포함).")
            }
            if level >= 3 {
                ContextPill(text: "작업공간 \(frontdoor.workspaceCount)", color: .secondary)
            }
        }
    }

    private func commitName(_ frontdoor: FrontdoorSession) {
        settings.setFrontdoorName(nameDraft, id: frontdoor.id)
        editingName = false
    }
}

private struct ContextPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.11), in: Capsule())
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.weight(.semibold))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct FrontdoorRow: View {
    @EnvironmentObject private var settings: AppSettings
    let frontdoor: FrontdoorSession
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ProviderIcon(provider: frontdoor.provider, size: 18)
                .overlay(alignment: .bottomTrailing) {
                    if frontdoor.isActive {
                        // Orange while a member waits on the person.
                        Circle().fill(statusColor(frontdoor.statusKey)).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(settings.frontdoorName(id: frontdoor.id, auto: frontdoor.displayName))
                        .font(.callout.weight(.medium)).lineLimit(1)
                    // Always stated, so a resting row and a closed one
                    // (both "실행 중 0" below) are told apart.
                    Text(frontdoor.statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor(frontdoor.statusKey))
                        .lineLimit(1)
                        .fixedSize()
                }
                // No opaque instance id, no LOCAL/ACP source — neither is
                // something a reader acts on. The name identifies the row; the
                // counts and current task are what tell it apart.
                Text(frontdoor.countsLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let task = frontdoor.latestTask, task != frontdoor.displayName {
                    Text(task).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct EventRow: View {
    @EnvironmentObject private var settings: AppSettings
    let event: MonitorEvent
    let session: GatewaySession?
    /// A call listed under its expanded tool group.
    var nested = false

    var body: some View {
        if event.kind == "tool_call" {
            // A tool call is a compact one-line header; the output is in the
            // detail pane on click.
            HStack(spacing: 8) {
                if event.isInFlight {
                    ProgressView().controlSize(.mini).frame(width: 18)
                } else {
                    Image(systemName: eventSymbol(event))
                        .foregroundStyle(eventColor(event)).frame(width: 18)
                }
                if event.isHookObserved { HookMarker() }
                Text(event.compactToolTitle(limit: nested ? 48 : 40))
                    .font(nested ? .caption : .callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let status = event.stateLabel, !event.isInFlight {
                    Text(status).font(.caption2).foregroundStyle(eventColor(event))
                }
                Spacer()
                Text(shortTime(event.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.vertical, nested ? 1 : 3)
            .padding(.leading, nested ? 22 : 0)
            .help(event.title ?? event.summary)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: eventSymbol(event))
                    .foregroundStyle(eventColor(event)).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(event.kindLabel).font(.callout.weight(.medium))
                        if let state = event.stateLabel {
                            Text(state).font(.caption2.weight(.semibold)).foregroundStyle(eventColor(event))
                        }
                        Spacer()
                        Text(shortTime(event.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Text(event.summary)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let session { Text(settings.sessionName(session)).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A run of tool calls as one list row: count, representative call,
/// failures, and a chevron; clicking it expands the calls below.
struct ToolGroupRow: View {
    let group: ToolCallGroup
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if group.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(group.failedCount > 0 ? .red : .cyan)
            }
            if group.isHookObserved { HookMarker() }
            Text(group.summary(titleLimit: 32))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(shortTime(group.representative.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(expanded ? "도구 호출 \(group.events.count)개 접기" : "도구 호출 \(group.events.count)개 펼치기")
    }
}

/// "실시간" when updates arrive as they happen, and a note when the source
/// cannot see permission prompts — so "nothing is waiting" is not confused
/// with "can't tell".
struct SessionCapabilityBadges: View {
    let session: GatewaySession
    /// Shown from history (browsed, or moved there when its idle hold ran
    /// out): no longer updating, so no "실시간" and no hook note.
    var inHistory = false

    var body: some View {
        let live = session.showsRealtimeBadge(inHistory: inHistory)
        let blind = session.showsPermissionBlindNote(inHistory: inHistory)
        if live || blind || !session.alerts.isEmpty {
            HStack(spacing: 6) {
                ForEach(session.alerts, id: \.code) { alert in
                    Label(alert.badge, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help(alert.tooltip)
                }
                if live {
                    Label("실시간", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.11), in: Capsule())
                        .help("hook 또는 Gateway 스트림으로 바로 갱신됩니다")
                }
                if blind {
                    Text("권한 대기 감지 불가 (hook 꺼짐)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("이 세션의 권한 요청은 보이지 않습니다. 설정 > 모니터링에서 hook을 켜면 감지합니다.")
                }
            }
        }
    }
}

/// One persisted session in "지난 기록": provider, folder or title, role and
/// how long ago it was last updated.
private struct HistorySessionRow: View {
    @EnvironmentObject private var settings: AppSettings
    let session: GatewaySession

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ProviderIcon(provider: session.provider, size: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout).lineLimit(1)
                // "3분 전" keeps counting while the list stays open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(subtitle(now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help(ifPresent: session.title ?? (session.cwd.isEmpty ? nil : session.cwd))
    }

    // Naming policy: the session's name (override, title, or provider ·
    // folder) leads; the folder goes in the subtitle so rows from one project
    // are still told apart by what they were doing.
    private var name: String { settings.sessionName(session) }

    private func subtitle(now: Date) -> String {
        var parts = [session.isFrontdoorRecord ? "Frontdoor" : "Worker"]
        let folder = (session.cwd as NSString).lastPathComponent
        if !folder.isEmpty, folder != "/", !name.contains(folder) { parts.append(folder) }
        if let updated = session.updatedAt.flatMap(parseTimestamp) {
            parts.append(relativeTimeText(from: updated, to: now))
        }
        return parts.joined(separator: " · ")
    }
}

/// The retained error/notice log. Text is selectable so an error can finally
/// be copied instead of read off a one-second flash.
private struct NoticeLogView: View {
    let entries: [NoticeEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("최근 알림 · 오류").font(.headline)
            if entries.isEmpty {
                Text("기록된 알림이 없습니다.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.at.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if entry.count > 1 {
                                    Text("×\(entry.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(14)
        .frame(width: 420)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(title, systemImage: symbol).font(.headline) }
    }
}

/// A folded inspector section (Gateway 상태, 미응답 요청, 태스크).
private struct InspectorDisclosure<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                Label(title, systemImage: symbol).font(.headline)
            }
        }
    }
}

/// Which folded inspector sections are open. In memory only: each launch
/// starts folded, and reopening the dashboard window keeps the choice.
@MainActor
final class InspectorDisclosures: ObservableObject {
    static let shared = InspectorDisclosures()
    @Published var gateway = false
    @Published var inbox = false
    @Published var tasks = false
}

extension AppModel {
    /// Shown from history rather than the live snapshot: the opened history
    /// session, or one kept only in history (its idle hold ran out).
    func showsAsHistory(_ session: GatewaySession) -> Bool {
        isHistorySession(
            session.sessionId,
            liveSessionIds: Set(sessions.map(\.sessionId)),
            openedHistoryId: selectedHistorySessionId
        )
    }
}

private struct RecordRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let record: MonitorRecord
    /// The session a task/inbox row belongs to, by its name — the raw id stays
    /// in the tooltip.
    private var sessionText: String {
        if let session = model.knownSession(record.subtitle) { return settings.sessionName(session) }
        return record.subtitle == record.id ? "" : "세션 정보 없음"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.title).font(.caption.weight(.medium)).lineLimit(2)
                Spacer()
                if let status = record.status { Text(recordStatusLabel(status)).foregroundStyle(statusColor(status)) }
            }
            if !sessionText.isEmpty {
                Text(sessionText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .help("세션 id: \(record.subtitle)")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}
