import AppKit
import SwiftUI

/// Compact popover shown from the menu-bar status item. Reuses the single
/// shared `AppModel`/`AppSettings` instance — no separate connection state.
struct MenuBarStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    private let recentSessionLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            metricsRow
            Divider()
            recentSection
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
        .task { model.startIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ACPLogoMark().frame(width: 20, height: 20)
            Circle().fill(connectionColor).frame(width: 8, height: 8)
            Text(connectionText).font(.callout.weight(.medium)).lineLimit(1)
            Spacer()
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 14) {
            MenuBarMetric(title: "Frontdoor", value: "\(model.activeFrontdoors.count)")
            MenuBarMetric(title: "Worker", value: "\(model.realtimeSessions.count)")
            MenuBarMetric(title: "대기 요청", value: "\(model.pendingInbox.count)")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("최근 세션").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if recentSessions.isEmpty {
                Text("활성 세션 없음").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(recentSessions) { frontdoor in
                    Button {
                        openSession(frontdoor)
                    } label: {
                        MenuBarSessionRow(frontdoor: frontdoor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("대시보드 열기") {
                model.startIfNeeded()
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Lynk Monitoring 열기") {
                model.startIfNeeded()
                openWindow(id: "live-graph")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .buttonStyle(.borderless)
    }

    private var recentSessions: [FrontdoorSession] {
        Array(model.visibleFrontdoors.prefix(recentSessionLimit))
    }

    private func openSession(_ frontdoor: FrontdoorSession) {
        model.startIfNeeded()
        model.selectedFrontdoorId = frontdoor.id
        if let sessionId = frontdoor.root?.sessionId ?? frontdoor.workers.first?.sessionId {
            model.selectedSessionId = sessionId
            openWindow(id: "session-detail", value: sessionId)
        } else {
            openWindow(id: "dashboard")
        }
        NSApp.activate(ignoringOtherApps: true)
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

private struct MenuBarSessionRow: View {
    let frontdoor: FrontdoorSession
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(frontdoor.isActive ? .blue : .secondary).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(frontdoor.displayName).font(.caption).lineLimit(1)
                if let task = frontdoor.latestTask {
                    Text(task).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
