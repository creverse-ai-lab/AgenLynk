import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

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
    }

    private func runtimeErrorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ACPLogoMark().frame(width: 40, height: 40)
            Text("Gateway runtime 설치 실패").font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.red).font(.callout)
            Button("다시 시도") { model.retryRuntimeProvisioning() }
                .buttonStyle(.borderedProminent)
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
            HSplitView {
                sessionColumn
                    .frame(minWidth: 170, idealWidth: 190, maxWidth: 340)
                eventColumn
                    .frame(minWidth: 420, idealWidth: 820)
                operationsColumn
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 440)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ACPApplicationIconUpdater().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItemGroup {
                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                }
                // Live monitoring now lives in the menu-bar popover; a second
                // entry point here was the same window twice.
                Button("다시 연결", systemImage: "arrow.clockwise") { model.reconnect() }
            }
        }
        .onChange(of: model.selectedFrontdoorId) { _, _ in
            settings.followLatestEvent = false
            model.selectedEventId = nil
            if model.selectedSession?.openerInstanceId != model.selectedFrontdoorId {
                model.selectedSessionId = model.selectedFrontdoor?.root?.sessionId
                    ?? model.selectedFrontdoor?.workers.first?.sessionId
            }
        }
        .onChange(of: model.selectedSessionId) { _, _ in
            settings.followLatestEvent = false
            model.selectedEventId = nil
            if let openerInstanceId = model.selectedSession?.openerInstanceId,
               openerInstanceId != model.selectedFrontdoorId {
                model.selectedFrontdoorId = openerInstanceId
            }
        }
    }

    @State private var showNoticeLog = false

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
            }
            if !model.noticeLog.isEmpty {
                Button { showNoticeLog = true } label: {
                    Label("\(model.noticeLog.count)", systemImage: "bell.badge")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showNoticeLog, arrowEdge: .bottom) {
                    NoticeLogView(entries: model.noticeLog)
                }
            }
            Spacer()
            Text("Gateway \(model.gatewayVersion)").foregroundStyle(.secondary)
            Text("build \(model.gatewayBuild)").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private var metricStrip: some View {
        HStack(spacing: 12) {
            MetricCard(title: "활성 Frontdoor", value: "\(model.activeFrontdoors.count)", symbol: "bolt.fill", color: .blue)
            MetricCard(
                title: "실행 Agent · ACP \(model.realtimeACPCount) / Local \(model.realtimeLocalCount)",
                value: "\(model.realtimeSessions.count)",
                symbol: "person.2.wave.2",
                color: .cyan
            )
            MetricCard(title: "대기 요청", value: "\(model.pendingInbox.count)", symbol: "exclamationmark.bubble", color: .orange)
            MetricCard(title: "태스크", value: "\(model.tasks.count)", symbol: "checklist", color: .green)
            MetricCard(title: "보관 이벤트", value: model.totalEventCount.formatted(), symbol: "waveform.path.ecg", color: .purple)
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
            }
            .padding(10)
            Divider()
            List(model.visibleFrontdoors, selection: $model.selectedFrontdoorId) { frontdoor in
                FrontdoorRow(frontdoor: frontdoor)
                    .tag(frontdoor.id)
            }
            .listStyle(.sidebar)
        }
    }

    private var eventColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(model.selectedFrontdoorId == nil ? "전체 이벤트 시퀀스" : "Frontdoor 이벤트 시퀀스", systemImage: "timeline.selection")
                    .font(.headline)
                Spacer()
                Text("\(model.selectedEvents.count)개").foregroundStyle(.secondary).font(.caption)
            }
            .padding(12)
            Divider()
            SequenceSelectionContext(
                frontdoor: model.selectedFrontdoor,
                session: model.selectedSession,
                activity: model.selectedSession.map { sessionActivity(for: $0) }
            )
            Divider()
            EventSequenceView(
                sessions: model.visibleLogSessions,
                events: model.selectedEvents,
                selectedSessionId: $model.selectedSessionId,
                selectedEventId: $model.selectedEventId,
                followLatestEvent: $settings.followLatestEvent
            )
        }
    }

    /// What the clicked agent is doing right now, read from the newest event
    /// of its session — the selection context leads with this instead of a bare
    /// status word, because "무엇을 하는 중인가" is the question the top strip is
    /// there to answer.
    private func sessionActivity(for session: GatewaySession) -> SessionActivity {
        let events = model.eventsBySession[session.sessionId] ?? []
        let latest = events.max(by: withinSessionEventOrder)
        let detail: String? = {
            guard let latest else { return session.title }
            if let merged = mergedChunkBody(for: latest, in: events) { return merged.text }
            if let body = latest.bodyText { return body }
            let summary = latest.summary
            return summary.isEmpty ? session.title : summary
        }()
        let type = latest?.type ?? ""

        switch session.status {
        case "waiting_permission":
            return SessionActivity(symbol: "hand.raised.fill", color: .orange, headline: "권한 요청 대기 중", detail: detail)
        case "waiting_input":
            return SessionActivity(symbol: "keyboard", color: .orange, headline: "사용자 입력 대기 중", detail: detail)
        default:
            break
        }
        if session.isActive {
            if type.hasPrefix("tool_call") {
                return SessionActivity(symbol: "wrench.and.screwdriver.fill", color: .cyan, headline: "도구 실행 중", detail: detail)
            }
            if type == "agent_thought_chunk" {
                return SessionActivity(symbol: "brain.head.profile", color: .purple, headline: "사고 중", detail: detail)
            }
            if type == "agent_message_chunk" {
                return SessionActivity(symbol: "text.bubble.fill", color: .blue, headline: "답변 생성 중", detail: detail)
            }
            return SessionActivity(symbol: "bolt.fill", color: .green, headline: "작업 진행 중", detail: detail)
        }
        switch session.status {
        case "ready", "idle", "end_turn", "completed", "closed":
            return SessionActivity(symbol: "checkmark.circle.fill", color: .green, headline: "최근 작업 완료", detail: detail)
        case "error":
            return SessionActivity(symbol: "exclamationmark.triangle.fill", color: .red, headline: "오류로 중단됨", detail: detail)
        default:
            return SessionActivity(symbol: "pause.circle", color: .secondary, headline: session.status, detail: detail)
        }
    }

    private var operationsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection(title: "선택 이벤트", symbol: "doc.text.magnifyingglass") {
                    if let event = model.selectedEvent {
                        if let session = model.visibleLogSessions.first(where: { $0.sessionId == event.sessionId }) {
                            LabeledContent("세션", value: session.provider.capitalized)
                            LabeledContent("모델", value: session.model ?? "default")
                            LabeledContent("역할", value: session.isFrontdoorRecord ? "Frontdoor" : "Worker")
                        }
                        LabeledContent("이벤트", value: event.type.replacingOccurrences(of: "_", with: " "))
                        LabeledContent("시간", value: shortTime(event.timestamp))
                            .lineLimit(1)
                        Divider()
                        // Same body-first treatment as the session detail pane;
                        // this column is an inspector, not an export, so the
                        // JSON only has to stay reachable, not lead. Siblings
                        // let a selected stream fragment show its whole message
                        // — the sequence diagram collapses a chunk run into one
                        // ×N node whose representative is the *last* fragment.
                        EventBodyView(
                            event: event,
                            siblings: model.eventsBySession[event.sessionId] ?? [],
                            characterLimit: 4_000,
                            bodyFont: .caption
                        )
                    } else {
                        EmptyLabel("이벤트를 선택하세요")
                    }
                }
                InspectorSection(title: "Gateway 상태", symbol: "network") {
                    LabeledContent("연결", value: model.connectionDetail)
                    LabeledContent("Persistence", value: model.persistenceHealthy.map { $0 ? "정상" : "오류" } ?? "—")
                    LabeledContent("감지 Provider", value: model.detectedProviderCount.formatted())
                }
                InspectorSection(title: "Inbox", symbol: "tray.full") {
                    if model.inbox.isEmpty { EmptyLabel("요청 없음") }
                    ForEach(model.inbox) { RecordRow(record: $0) }
                }
                InspectorSection(title: "Tasks", symbol: "checklist") {
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
        if case .starting = model.phase { return .blue }
        return .red
    }

    private var connectionText: String {
        switch model.phase {
        case .idle: "대기 중"
        case .starting: "Observer monitor 시작 중…"
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
    let frontdoor: FrontdoorSession?
    let session: GatewaySession?
    var activity: SessionActivity? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let frontdoor {
                VStack(alignment: .leading, spacing: 5) {
                    // Lead with the Frontdoor's name, not the label "선택
                    // Frontdoor". The opaque instance id it used to emphasise
                    // told a reader nothing, so it is gone.
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack").font(.caption).foregroundStyle(.secondary)
                        Text(frontdoor.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        ContextPill(text: frontdoor.provider.capitalized, color: .blue)
                        ContextPill(text: frontdoor.isActive ? "진행 중" : "대기", color: frontdoor.isActive ? .green : .secondary)
                        ContextPill(text: "Worker \(frontdoor.workers.count)", color: .secondary)
                        ContextPill(text: "작업공간 \(frontdoor.workspaceCount)", color: .secondary)
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
                VStack(alignment: .leading, spacing: 5) {
                    Label("선택 에이전트", systemImage: "rectangle.and.hand.point.up.left")
                        .font(.caption.weight(.semibold))
                    // What it is doing now, front and centre — the status word
                    // is demoted to a small pill next to the identity.
                    if let activity {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: activity.symbol)
                                .foregroundStyle(activity.color)
                                .font(.callout)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.headline)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(activity.color)
                                if let detail = activity.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        // The LOCAL/ACP source is not something a reader acts
                        // on; role and model are.
                        ContextPill(text: session.isFrontdoorRecord ? "Frontdoor" : "Worker", color: .secondary)
                        Text("\(session.provider.capitalized) · \(session.model ?? "default")")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if frontdoor == nil, session == nil {
                Label("왼쪽 Frontdoor 또는 시퀀스 에이전트를 선택하면 지금 무엇을 하는지 표시됩니다", systemImage: "cursorarrow.click")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ContextPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
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
    let frontdoor: FrontdoorSession
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(frontdoor.isActive ? .blue : .secondary).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(frontdoor.displayName).font(.callout.weight(.medium)).lineLimit(1)
                // No opaque instance id, no LOCAL/ACP source — neither is
                // something a reader acts on. The name identifies the row; the
                // counts and current task are what tell it apart.
                Text("Worker \(frontdoor.workers.count) · 진행 중 \(frontdoor.activeWorkerCount) · 작업공간 \(frontdoor.workspaceCount)")
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
    let event: MonitorEvent
    let session: GatewaySession?
    /// >1 when this row stands for a whole run of streamed chunks.
    var collapsedCount: Int = 1
    /// The run's merged text — the representative event is only its newest
    /// fragment, so its own summary would show the tail of the message.
    var summaryOverride: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: eventSymbol(event.type))
                .foregroundStyle(eventColor(event.type)).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.type.replacingOccurrences(of: "_", with: " ")).font(.callout.weight(.medium))
                    if collapsedCount > 1 {
                        Text("×\(collapsedCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(shortTime(event.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(summaryOverride.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(140)) } ?? event.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let session { Text(session.displayName).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 4)
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

private struct RecordRow: View {
    let record: MonitorRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.title).font(.caption.weight(.medium)).lineLimit(2)
                Spacer()
                if let status = record.status { Text(status).foregroundStyle(statusColor(status)) }
            }
            Text(record.subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}
