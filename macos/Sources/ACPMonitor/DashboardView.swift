import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            metricStrip
            Divider()
            HSplitView {
                sessionColumn
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 340)
                eventColumn
                    .frame(minWidth: 420, idealWidth: 660)
                operationsColumn
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ACPApplicationIconUpdater().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItemGroup {
                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                }
                Button("Live Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                    openWindow(id: "live-graph")
                }
                Button("다시 연결", systemImage: "arrow.clockwise") { model.reconnect() }
            }
        }
        .task { model.startIfNeeded() }
    }

    private var connectionBar: some View {
        HStack(spacing: 9) {
            ACPLogoMark().frame(width: 27, height: 27)
            Divider().frame(height: 22)
            Circle().fill(connectionColor).frame(width: 9, height: 9)
            Text(connectionText).font(.callout.weight(.medium))
            if let notice = model.lastNotice {
                Text(notice).font(.caption).foregroundStyle(.orange).lineLimit(1)
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
            MetricCard(title: "활성 세션", value: "\(model.activeSessions.count)", symbol: "bolt.fill", color: .blue)
            MetricCard(title: "전체 세션", value: "\(model.sessions.count)", symbol: "rectangle.stack", color: .secondary)
            MetricCard(title: "대기 요청", value: "\(model.pendingInbox.count)", symbol: "exclamationmark.bubble", color: .orange)
            MetricCard(title: "태스크", value: "\(model.tasks.count)", symbol: "checklist", color: .green)
            MetricCard(title: "보관 이벤트", value: model.totalEventCount.formatted(), symbol: "waveform.path.ecg", color: .purple)
        }
        .padding(12)
    }

    private var sessionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("세션", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Toggle("활성만", isOn: $settings.activeOnly).toggleStyle(.checkbox).font(.caption)
            }
            .padding(12)
            Divider()
            List(model.visibleSessions, selection: $model.selectedSessionId) { session in
                SessionRow(session: session)
                    .tag(session.sessionId)
                    .contextMenu {
                        Button("별도 창에서 열기") {
                            openWindow(id: "session-detail", value: session.sessionId)
                        }
                    }
            }
            .listStyle(.sidebar)
            if let sessionId = model.selectedSessionId {
                Button("선택 세션 상세 창 열기", systemImage: "macwindow.badge.plus") {
                    openWindow(id: "session-detail", value: sessionId)
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        }
    }

    private var eventColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(model.selectedSessionId == nil ? "전체 이벤트" : "세션 이벤트", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(model.selectedEvents.count)개").foregroundStyle(.secondary).font(.caption)
            }
            .padding(12)
            Divider()
            List(model.selectedEvents, selection: $model.selectedEventId) { event in
                EventRow(event: event, session: model.sessions.first { $0.sessionId == event.sessionId })
                    .tag(event.id)
            }
            .listStyle(.inset)
        }
    }

    private var operationsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorSection(title: "선택 이벤트", symbol: "doc.text.magnifyingglass") {
                    if let event = model.selectedEvent {
                        Text(event.payload.prettyPrinted)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

struct SessionRow: View {
    let session: GatewaySession
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(statusColor(session.status)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(session.provider).foregroundStyle(providerColor(session.provider))
                    Text("· \(session.model ?? "default") · \(session.status)")
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(session.cwd).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct EventRow: View {
    let event: MonitorEvent
    let session: GatewaySession?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: eventSymbol(event.type))
                .foregroundStyle(eventColor(event.type)).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.type.replacingOccurrences(of: "_", with: " ")).font(.callout.weight(.medium))
                    Spacer()
                    Text(shortTime(event.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(event.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let session { Text(session.displayName).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 4)
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
