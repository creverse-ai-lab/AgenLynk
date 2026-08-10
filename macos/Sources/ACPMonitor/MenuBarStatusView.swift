import AppKit
import SwiftUI

/// Popover shown from the menu-bar status item. Reuses the single shared
/// `AppModel`/`AppSettings` instance — no separate connection state.
///
/// This is a liveness surface, not a second Monitoring window: it answers
/// "is anything actually progressing right now?" with the stream heartbeat and
/// the same `PetActivityProjection` states the Pet renderer consumes. The full
/// graph stays one click away in the Monitoring window.
///
/// Every section has a fixed height so the popover frame never changes size.
/// `MenuBarExtra(.window)` keeps the largest content size it has shown, so a
/// layout that grows and shrinks leaves the window stuck at its widest.
struct MenuBarStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    private let popoverWidth: Double = 460
    private let contentPadding: Double = 14
    private let activityListHeight: Double = 210
    private let graphLabelWidth: Double = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            // One shared clock drives every relative timestamp, so the seconds
            // visibly tick while the popover is open. A frozen counter is
            // itself the signal that nothing is arriving.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    heartbeat(now: context.date)
                    Divider()
                    metricsRow
                    Divider()
                    activitySection(now: context.date)
                }
            }
            Divider()
            actions
        }
        .padding(contentPadding)
        .frame(width: popoverWidth)
        .task { model.startIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ACPLogoMark().frame(width: 20, height: 20)
            Circle().fill(connectionColor).frame(width: 8, height: 8)
            Text(connectionText).font(.callout.weight(.medium)).lineLimit(1)
            Spacer()
            Button {
                model.reconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Gateway monitor에 다시 연결합니다")
        }
    }

    /// Stream liveness. `streamingLive` is the Gateway's own view of the
    /// subscription; the timestamps show whether that subscription is still
    /// delivering.
    private func heartbeat(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: model.streamingLive ? "dot.radiowaves.left.and.right" : "bolt.horizontal.circle")
                    .foregroundStyle(streamColor(now: now))
                Text(model.streamingLive ? "이벤트 스트림 수신 중" : "스트림 미연결")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(streamColor(now: now))
                Spacer()
                Text(model.lastStreamMessageAt.map { "\(relative(from: $0, to: now)) 갱신" } ?? "수신 없음")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("마지막 Agent 이벤트")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(model.lastAgentEventAt.map { relative(from: $0, to: now) } ?? "이번 실행에서 없음")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let notice = model.lastNotice {
                Text(notice).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            MenuBarMetric(title: "Frontdoor", value: "\(model.activeFrontdoors.count)")
            MenuBarMetric(title: "Worker", value: "\(model.realtimeSessions.count)")
            MenuBarMetric(title: "대기 요청", value: "\(model.pendingInbox.count)")
            MenuBarMetric(title: "이벤트", value: model.totalEventCount.formatted())
        }
    }

    /// The Monitoring window's live projection, restricted to sessions that are
    /// running right now — the same `windowMinutes: 1, currentTurnsOnly` scope
    /// the window uses.
    private var liveProjection: GraphProjection {
        GraphProjection.make(
            sessions: model.realtimeSessions,
            eventsBySession: model.eventsBySession,
            windowMinutes: 1,
            currentTurnsOnly: true
        )
    }

    private func activitySection(now: Date) -> some View {
        let projection = liveProjection
        let hasLiveLanes = !projection.lanes.isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hasLiveLanes ? "진행 중인 세션" : "최근 Agent 상태")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(hasLiveLanes
                    ? "\(projection.lanes.count) lane · \(projection.turnCount) turn"
                    : progressSummary(sortedAgents))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Group {
                if hasLiveLanes {
                    ScrollView(.vertical) {
                        MenuBarLiveGraph(projection: projection, timelineWidth: timelineWidth)
                    }
                } else {
                    // Nothing is running: fall back to the normalized states so
                    // the box still says what each known session was last doing.
                    recentActivityList(now: now)
                }
            }
            .frame(height: activityListHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private var timelineWidth: Double {
        popoverWidth - contentPadding * 2 - graphLabelWidth - 1
    }

    private func recentActivityList(now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if sortedAgents.isEmpty {
                    Text("알려진 Agent 세션이 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(sortedAgents, id: \.id) { agent in
                        Button { open(agent) } label: {
                            MenuBarActivityRow(agent: agent, now: now)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("대시보드 열기") {
                model.startIfNeeded()
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    private var sortedAgents: [PetAgentActivity] { model.activityProjection.orderedByProgress }

    private func progressSummary(_ agents: [PetAgentActivity]) -> String {
        let running = agents.filter { $0.state == .running || $0.state == .starting }.count
        let waiting = agents.filter { $0.state == .waiting }.count
        if running == 0 && waiting == 0 { return "진행 중 없음" }
        if waiting == 0 { return "진행 중 \(running)" }
        if running == 0 { return "응답 대기 \(waiting)" }
        return "진행 중 \(running) · 응답 대기 \(waiting)"
    }

    private func open(_ agent: PetAgentActivity) {
        model.startIfNeeded()
        if agent.role == "worker" {
            model.selectedFrontdoorId = agent.parentId
            model.selectedSessionId = agent.id
            openWindow(id: "session-detail", value: agent.id)
        } else {
            model.selectedFrontdoorId = agent.id
            openWindow(id: "dashboard")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func streamColor(now: Date) -> Color {
        guard model.streamingLive else { return .red }
        guard let last = model.lastStreamMessageAt else { return .orange }
        return now.timeIntervalSince(last) > 90 ? .orange : .green
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
        case .starting: "시작 중…"
        case .connected: "Gateway 연결됨"
        case let .degraded(message): message
        case let .disconnected(message): message
        }
    }
}

private struct MenuBarActivityRow: View {
    let agent: PetAgentActivity
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(stateLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(stateColor)
                    Text(agent.provider.capitalized)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(agent.role == "worker" ? "Worker" : "Frontdoor")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if agent.inboxPending > 0 {
                        Text("요청 \(agent.inboxPending)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    Text(relative(from: agent.updatedAt, to: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let task = agent.task, !task.isEmpty {
                    Text(task).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var stateLabel: String {
        switch agent.state {
        case .running: "진행 중"
        case .waiting: "응답 대기"
        case .starting: "시작 중"
        case .completed: "완료"
        case .failed: "실패"
        case .idle: "대기"
        case .offline: "오프라인"
        case .unknown: "알 수 없음"
        }
    }

    private var stateColor: Color {
        switch agent.state {
        case .running, .starting: .green
        case .waiting: .orange
        case .failed: .red
        case .completed: .blue
        case .idle, .offline, .unknown: .secondary
        }
    }
}

/// Relative timestamps for the popover. Deliberately coarse and monospaced so
/// the digits tick in place instead of reflowing the row.
private func relative(from date: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date).rounded())
    if seconds < 0 { return "방금" }
    if seconds < 3 { return "방금" }
    if seconds < 60 { return "\(seconds)초 전" }
    if seconds < 3_600 { return "\(seconds / 60)분 전" }
    if seconds < 86_400 { return "\(seconds / 3_600)시간 전" }
    return "\(seconds / 86_400)일 전"
}

private struct MenuBarMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
