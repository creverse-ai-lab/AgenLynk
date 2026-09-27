import ACPShared
import AppKit
import SwiftUI

/// The menu bar popover: work in progress as pipelines. One card per
/// Frontdoor shows its sessions as the delegation chain (Frontdoor → Worker →
/// nested Worker) with each step's status, the step that needs the user
/// called out, and this turn's tokens against the usual. Everything else
/// (idle work, connection detail) is folded away.
struct MenuBarStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showIdle = false
    @State private var showConnection = false

    private let popoverWidth: Double = 440
    private let contentPadding: Double = 14

    var body: some View {
        // Cached by the model per monitor-state revision; the one-second
        // TimelineView below only redraws elapsed times.
        let pipeline = model.menuBarPipeline
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                header(now: context.date)
                summary(pipeline)
                if model.hookStatus?.consentRequired == true { hookPrompt }
                Divider()
                pipelines(pipeline, now: context.date)
                if !pipeline.idleCards.isEmpty { idleSection(pipeline, now: context.date) }
                Divider()
                if showConnection { connectionDetail(now: context.date) }
                actions
            }
        }
        .padding(contentPadding)
        .frame(width: popoverWidth)
        .task { model.startIfNeeded() }
    }

    // MARK: Header and summary

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            ACPLogoMark().frame(width: 20, height: 20)
            Circle().fill(connectionColor).frame(width: 8, height: 8)
            Text(connectionText).font(.callout.weight(.medium)).lineLimit(1)
            StreamFreshnessText(heartbeat: model.heartbeat, streamingLive: model.streamingLive, now: now)
            Spacer()
            Button {
                showConnection.toggle()
            } label: {
                Image(systemName: showConnection ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(.borderless)
            .help(showConnection ? "연결 상세 접기" : "연결 상세 보기")
            .accessibilityLabel(showConnection ? "연결 상세 접기" : "연결 상세 보기")
            Button {
                model.reconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("모니터에 다시 연결합니다. Gateway와 에이전트는 멈추지 않습니다.")
            .accessibilityLabel("모니터 다시 연결")
        }
    }

    /// "작업 3 · 실행 중 4 · 권한 대기 1 · 입력 대기 0" — the counts that say
    /// whether anything needs the user right now.
    private func summary(_ pipeline: MenuBarPipeline) -> some View {
        HStack(spacing: 10) {
            summaryItem("작업", pipeline.activeCards.count, color: .primary)
            summaryItem("실행 중", pipeline.runningCount, color: .green)
            summaryItem("권한 대기", pipeline.permissionCount, color: .orange)
            summaryItem("입력 대기", pipeline.inputCount, color: .orange)
            Spacer()
        }
        .font(.caption)
    }

    private func summaryItem(_ title: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(count > 0 ? color : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var hookPrompt: some View {
        Button {
            model.hookConsentPresented = true
            openDashboard()
        } label: {
            Label("실시간 모니터링이 꺼져 있습니다 · 켜기…", systemImage: "bolt.horizontal.circle")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.orange)
        .help("hook을 켜면 도구 실행·권한 대기·턴 종료가 바로 보입니다")
    }

    // MARK: Pipelines

    @ViewBuilder
    private func pipelines(_ pipeline: MenuBarPipeline, now: Date) -> some View {
        if pipeline.activeCards.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("진행 중인 작업이 없습니다")
                    .font(.callout.weight(.medium))
                Text(pipeline.idleCards.isEmpty
                    ? "터미널에서 claude · codex · grok을 실행하면 여기에 파이프라인으로 표시됩니다."
                    : "대기 중인 작업은 아래에서 볼 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pipeline.activeCards) { card in
                        PipelineCardView(
                            card: card,
                            now: now,
                            openFrontdoor: { openDashboard(frontdoorId: card.frontdoor.id) },
                            openStage: { stage in openDashboard(frontdoorId: card.frontdoor.id, sessionId: stage.id) }
                        )
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func idleSection(_ pipeline: MenuBarPipeline, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showIdle.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showIdle ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("대기 중 작업 \(pipeline.idleCards.count)개").font(.caption.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(showIdle ? "대기 중 작업 접기" : "대기 중 작업 \(pipeline.idleCards.count)개 펼치기")
            if showIdle {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pipeline.idleCards) { card in
                            IdleWorkRow(card: card, now: now) { openDashboard(frontdoorId: card.frontdoor.id) }
                        }
                    }
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Connection and actions

    private func connectionDetail(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            detailLine("이벤트 스트림", model.streamingLive ? "수신 중" : "연결 안 됨")
            HeartbeatDetailLines(heartbeat: model.heartbeat, now: now)
            detailLine("미응답 요청", "\(model.pendingInbox.count)개")
            if let notice = model.lastNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(notice)
            }
        }
        .padding(.bottom, 4)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        MenuBarDetailLine(title: title, value: value)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("대시보드 열기") { openDashboard() }
                .buttonStyle(.borderless)
            Spacer()
            // SettingsLink is the only supported way to open the Settings
            // scene from a menu-bar popover on macOS 14. Activate too, or the
            // window opens behind the app.
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("설정")
            .accessibilityLabel("설정")
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
        }
    }

    /// Opens the dashboard scoped to a Frontdoor (and one of its sessions).
    private func openDashboard(frontdoorId: String? = nil, sessionId: String? = nil) {
        model.startIfNeeded()
        if let frontdoorId { model.selectedFrontdoorId = frontdoorId }
        if let sessionId { model.selectedSessionId = sessionId }
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var connectionColor: Color {
        if case .connected = model.phase { return .green }
        if case .degraded = model.phase { return .orange }
        if case .starting = model.phase { return .secondary }
        return .red
    }

    private var connectionText: String {
        switch model.phase {
        case .idle: "연결 준비 중"
        case .starting: "시작 중…"
        case .connected: "Gateway 연결됨"
        case let .degraded(message): message
        case let .disconnected(message): message
        }
    }
}

private struct MenuBarDetailLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.tertiary)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption2)
    }
}

/// "· 3초 전 갱신": the only header text that reads the stream heartbeat,
/// so it alone observes it — a clock-only frame re-renders nothing else.
private struct StreamFreshnessText: View {
    @ObservedObject var heartbeat: MonitorHeartbeat
    let streamingLive: Bool
    let now: Date

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var text: String {
        guard streamingLive else { return "· 스트림 미연결" }
        guard let last = heartbeat.lastStreamMessageAt else { return "· 수신 대기" }
        return "· \(relativeTimeText(from: last, to: now)) 갱신"
    }

    private var color: Color {
        guard streamingLive else { return .red }
        guard let last = heartbeat.lastStreamMessageAt else { return .orange }
        return now.timeIntervalSince(last) > 90 ? .orange : .secondary
    }
}

private struct HeartbeatDetailLines: View {
    @ObservedObject var heartbeat: MonitorHeartbeat
    let now: Date

    var body: some View {
        MenuBarDetailLine(title: "마지막 갱신", value: heartbeat.lastStreamMessageAt.map { relativeTimeText(from: $0, to: now) } ?? "수신 없음")
        MenuBarDetailLine(title: "마지막 에이전트 이벤트", value: heartbeat.lastAgentEventAt.map { relativeTimeText(from: $0, to: now) } ?? "이번 실행에서 없음")
    }
}

/// One Frontdoor's work as a pipeline card.
private struct PipelineCardView: View {
    @EnvironmentObject private var settings: AppSettings
    let card: MenuBarPipeline.Card
    let now: Date
    let openFrontdoor: () -> Void
    let openStage: (MenuBarPipeline.Stage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: openFrontdoor) {
                HStack(spacing: 6) {
                    ProviderIcon(provider: card.frontdoor.provider, size: 16)
                    Text(settings.frontdoorName(id: card.frontdoor.id, auto: card.frontdoor.displayName))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let total = card.work.totalTokens {
                        Text("작업 \(formatTokenCount(total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("이 작업(Frontdoor와 Worker들)의 세션 누적 토큰 합계입니다. 입력은 cache 포함.")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("대시보드에서 이 작업 보기")

            VStack(alignment: .leading, spacing: 1) {
                ForEach(card.stages) { stage in
                    Button { openStage(stage) } label: {
                        StageRow(stage: stage, now: now, isFocus: stage.id == card.focus?.id && stage.urgency <= .running)
                    }
                    .buttonStyle(.plain)
                    .help("대시보드에서 이 세션 보기")
                }
                if card.hiddenStageCount > 0 {
                    // Counted, never listed: the dashboard opens the box.
                    Label("대기 중 Worker \(card.hiddenStageCount)개", systemImage: "moon.zzz")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .restingBox(cornerRadius: 5)
                        .padding(.leading, 18)
                        .padding(.top, 2)
                }
            }

            if let focus = card.focus { FocusLine(stage: focus) }
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border))
    }

    private var background: Color {
        card.urgency.needsUser ? Color.orange.opacity(0.08) : Color(nsColor: .textBackgroundColor)
    }

    private var border: Color {
        card.urgency.needsUser ? Color.orange.opacity(0.45) : Color(nsColor: .separatorColor)
    }
}

/// One step of a pipeline: connector, status dot, provider, name, status.
private struct StageRow: View {
    @EnvironmentObject private var settings: AppSettings
    let stage: MenuBarPipeline.Stage
    let now: Date
    var isFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if stage.depth > 0 {
                    Text(String(repeating: "  ", count: stage.depth - 1) + "└")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Circle().fill(stageColor).frame(width: 7, height: 7)
                ProviderIcon(provider: stage.session.provider, size: 13)
                Text(settings.sessionName(stage.session))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(stage.session.isFrontdoorRecord ? "Frontdoor" : "Worker")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if stage.session.cannotObservePermission && stage.urgency <= .running {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("권한 대기 감지 불가 (hook 꺼짐) · 설정 > 모니터링에서 켤 수 있습니다")
                }
                Spacer(minLength: 4)
                if isFocus {
                    Text("← 현재").font(.caption2.weight(.semibold)).foregroundStyle(stageColor)
                }
                Text(statusText)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(stageColor)
                    .lineLimit(1)
            }
            if let reason = stage.waitReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(stage.depth) * 10 + 26)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "실행 중 · 4분째", "권한 대기 · 2분째", "대기".
    private var statusText: String {
        let label = sessionStatusLabel(stage.session.status)
        guard let started = stage.turnStartedAt, stage.urgency <= .running else { return label }
        return "\(label) · \(elapsedText(from: started, to: now))"
    }

    private var stageColor: Color { stage.color }
}

/// The card's call-out: what the most urgent step is doing and what this
/// turn has used against the usual.
private struct FocusLine: View {
    let stage: MenuBarPipeline.Stage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let step = stage.currentStep {
                Label(step, systemImage: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if stage.forecast.currentTurnRunning {
                HStack(spacing: 6) {
                    if let current = stage.forecast.currentTurnTokens {
                        Text("이번 턴 \(formatTokenCount(current))")
                    } else {
                        Text("이번 턴 집계 중").help("이 CLI는 턴이 끝날 때 토큰을 확정합니다.")
                    }
                    if let typical = stage.forecast.typicalTurnTokens {
                        Text("/ 예상 약 \(formatTokenCount(typical))").foregroundStyle(.secondary)
                        if let progress = stage.forecast.progress {
                            ProgressView(value: min(progress, 1))
                                .progressViewStyle(.linear)
                                .tint(progress > 1 ? .orange : .accentColor)
                                .frame(maxWidth: 90)
                        }
                    }
                    Spacer()
                }
                .font(.caption2.monospacedDigit())
                .help("예상치는 완료된 최근 턴들이 쓴 토큰의 중앙값입니다.")
            }
        }
        .padding(.leading, 2)
    }
}

/// A quiet Frontdoor, one line.
private struct IdleWorkRow: View {
    @EnvironmentObject private var settings: AppSettings
    let card: MenuBarPipeline.Card
    let now: Date
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                ProviderIcon(provider: card.frontdoor.provider, size: 13)
                Text(settings.frontdoorName(id: card.frontdoor.id, auto: card.frontdoor.displayName))
                    .font(.caption)
                    .lineLimit(1)
                Text(card.urgency == .closed ? "종료" : "대기")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let updated = card.frontdoor.updatedAt.flatMap(parseTimestamp) {
                    Text(relativeTimeText(from: updated, to: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let total = card.work.totalTokens {
                    Text(formatTokenCount(total))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("대시보드에서 이 작업 보기")
    }
}
