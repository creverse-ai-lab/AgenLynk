import ACPShared
import AppKit
import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    let sessionId: String?
    @State private var selectedEventId: String?
    @State private var expandedGroups: Set<String> = []
    /// Same follow rule as the dashboard sequence (docs/ux-policy.md §5): at
    /// the bottom it follows new events, scrolled up it stays put.
    @State private var following = true
    @State private var settled = false
    @State private var olderRequestInFlight = false
    @State private var lastAutoScroll = Date.distantPast
    private static let bottomId = "detail-bottom"

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                sessionHeader(session)
                Divider()
                sessionConfigPanel(session)
                Divider()
                HSplitView {
                    // One row per canonical event: the sidecar already merged
                    // a streamed response into one message and a tool call's
                    // updates into the call itself.
                    // Runs of tool calls collapse into one row; one continuous
                    // list that pages older events in when its top appears.
                    eventList(session)
                    .frame(minWidth: 430)
                    ScrollView {
                        if let selectedEvent {
                            EventBodyView(event: selectedEvent).padding(14)
                        } else {
                            ContentUnavailableView("이벤트를 선택하세요", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .frame(minWidth: 360)
                }
            }
            .navigationTitle(settings.sessionName(session))
            .task(id: sessionId) {
                guard let sessionId, session.role == "worker", !session.isLocalSource else { return }
                await model.loadSessionConfig(sessionId: sessionId)
            }
        } else {
            ContentUnavailableView("세션을 찾을 수 없습니다", systemImage: "questionmark.folder")
        }
    }

    /// One continuous list, newest at the bottom: it opens there and
    /// follows, pages older events in at the top without moving the view.
    private func eventList(_ session: GatewaySession) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("이벤트 \(events.count.formatted())개")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if following {
                        Label("최신 따라가는 중", systemImage: "arrow.down.to.line")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button("최신으로", systemImage: "arrow.down.to.line") { scrollToBottom(proxy, animated: true) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("가장 최근 이벤트로 이동하고 새 이벤트를 따라갑니다")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                Divider()
                List(selection: listSelection) {
                    if model.mayHaveOlderEvents(session.sessionId) || model.olderLoadingSessionIds.contains(session.sessionId) {
                        HStack(spacing: 6) {
                            if model.olderLoadingSessionIds.contains(session.sessionId) || olderRequestInFlight {
                                ProgressView().controlSize(.mini)
                                Text("이전 이벤트 불러오는 중")
                            } else {
                                Button("이전 이벤트 더 보기", systemImage: "arrow.up") {
                                    requestOlder(session, proxy: proxy, force: true)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .selectionDisabled()
                        .onAppear { requestOlder(session, proxy: proxy) }
                    }
                    ForEach(rows) { row in
                        switch row.content {
                        case let .event(event):
                            // The window is this session's: its name is in
                            // the title, not repeated on every row.
                            EventRow(event: event, session: nil, nested: row.parentGroupId != nil)
                                .tag(event.id)
                                .id(row.id)
                        case let .group(group, expanded):
                            ToolGroupRow(group: group, expanded: expanded)
                                .tag(group.id)
                                .id(row.id)
                        }
                    }
                    if rows.isEmpty {
                        Text(session.canShowTimeline ? "표시할 이벤트가 없습니다" : "이 소스에서는 이벤트 타임라인을 볼 수 없습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .selectionDisabled()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        .onAppear { following = true }
                        .onDisappear {
                            guard settled, Date().timeIntervalSince(lastAutoScroll) > 0.6 else { return }
                            following = false
                        }
                }
            }
            .onChange(of: events.last?.id) { _, _ in
                if following { scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: events.count) { _, _ in
                if following { scrollToBottom(proxy, animated: false) }
            }
            .task(id: sessionId) {
                // Open at the newest event, then let the top sentinel page.
                try? await Task.sleep(nanoseconds: 150_000_000)
                scrollToBottom(proxy, animated: false)
                try? await Task.sleep(nanoseconds: 550_000_000)
                settled = true
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        lastAutoScroll = Date()
        following = true
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
    }

    /// Loads the next older page and keeps the event that was on top in
    /// place (EventTimeline.anchorEventId), as the dashboard sequence does.
    private func requestOlder(_ session: GatewaySession, proxy: ScrollViewProxy, force: Bool = false) {
        guard force || settled, !olderRequestInFlight, model.mayHaveOlderEvents(session.sessionId) else { return }
        let anchor = EventTimeline.anchorEventId(in: rows)
        olderRequestInFlight = true
        Task { @MainActor in
            let arrived = await model.loadOlderEvents(sessionIds: [session.sessionId])
            olderRequestInFlight = false
            guard arrived, let anchor else { return }
            await Task.yield()
            guard let rowId = EventTimeline.rowId(showing: anchor, in: rows) else { return }
            proxy.scrollTo(rowId, anchor: .top)
        }
    }

    private var session: GatewaySession? {
        guard let sessionId else { return nil }
        return model.sessions.first { $0.sessionId == sessionId } ?? model.knownSession(sessionId)
    }
    private var events: [MonitorEvent] {
        let id = sessionId ?? ""
        return model.browsedEvents[id] ?? model.logEventsBySession[id] ?? []
    }
    private var selectedEvent: MonitorEvent? { events.first { $0.id == selectedEventId } }
    private var rows: [TimelineRow] {
        EventTimeline.rows(EventTimeline.group(events), expanded: expandedGroups)
    }

    /// Selecting a tool group's row expands (or collapses) it and shows its
    /// representative call; any other row selects its event.
    private var listSelection: Binding<String?> {
        Binding(
            get: { selectedEventId },
            set: { value in
                guard let value, value.hasPrefix("tools:") else {
                    selectedEventId = value
                    return
                }
                if expandedGroups.contains(value) {
                    expandedGroups.remove(value)
                } else {
                    expandedGroups.insert(value)
                }
                if case let .tools(group)? = EventTimeline.group(events).first(where: { $0.id == value }) {
                    selectedEventId = group.representative.id
                }
            }
        )
    }

    private func sessionHeader(_ session: GatewaySession) -> some View {
        HStack(spacing: 14) {
            Image(systemName: sessionStatusSymbol(session.status))
                .foregroundStyle(statusColor(session.status))
                .accessibilityLabel(sessionStatusLabel(session.status))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    ProviderIcon(provider: session.provider, size: 20)
                    SessionNameEditor(session: session)
                }
                Text([session.model, sessionStatusLabel(session.status)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text(session.cwd).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                SessionCapabilityBadges(session: session)
            }
            Spacer()
            // A running turn shows even before any usage is reported (Grok
            // settles its tokens only at the turn's end).
            let forecast = UsageForecast(session: session)
            if session.usage != nil || forecast.currentTurnRunning {
                SessionUsageView(usage: session.usage, partial: session.usagePartial, forecast: forecast)
                    .frame(maxWidth: 220)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(session.isFrontdoorRecord ? "Frontdoor" : "Worker").font(.caption).foregroundStyle(.secondary)
                if !session.isFrontdoorRecord, let opener = session.opener {
                    HStack(spacing: 4) {
                        Text("요청한 곳").font(.caption2).foregroundStyle(.tertiary)
                        ProviderIcon(provider: opener, size: 14)
                    }
                }
            }
        }
        .padding(16)
    }

    /// Worker-advertised per-session settings (ACP `session/config`). Mutation
    /// is blocked while the session is active or its config is unavailable
    /// (disconnected Worker, load error) — cached values still render so the
    /// panel isn't empty while blocked.
    private func sessionConfigPanel(_ session: GatewaySession) -> some View {
        let supportsSessionConfig = session.role == "worker" && !session.isLocalSource
        let matchesSession = model.sessionConfigSessionId == session.sessionId
        let displayingLoad = supportsSessionConfig && (!matchesSession || model.sessionConfigLoading)
        let unavailableStatus = ["disconnected", "unavailable", "closed"].contains(session.status)
        let mutationBlocked = session.isActive
            || unavailableStatus
            || displayingLoad
            || model.sessionConfigUnavailableReason != nil
            || model.sessionConfigSaving
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("세션 설정", systemImage: "slider.horizontal.below.square.filled.and.square")
                    .font(.callout.weight(.medium))
                if displayingLoad { ProgressView().controlSize(.small) }
                Spacer()
                if session.isActive {
                    Text("세션 실행 중 · 변경 불가").font(.caption).foregroundStyle(.orange)
                }
            }
            if !supportsSessionConfig {
                Text("ACP Worker 세션에서만 조정 가능한 설정을 제공합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if displayingLoad {
                Text("Worker 설정을 불러오는 중입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let reason = model.sessionConfigUnavailableReason {
                Label(reason, systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
            } else if let error = model.sessionConfigError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if model.sessionConfigOptions.isEmpty && !model.sessionConfigLoading {
                Text("이 Worker는 조정 가능한 세션 설정을 제공하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.sessionConfigOptions) { option in
                    SessionConfigRow(
                        option: option,
                        disabled: mutationBlocked,
                        onSelect: { value in
                            Task { await model.setSessionConfig(sessionId: session.sessionId, configId: option.id, value: .string(value)) }
                        },
                        onToggle: { value in
                            Task { await model.setSessionConfig(sessionId: session.sessionId, configId: option.id, value: .bool(value)) }
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One event rendered the way a reader asks about it: what it said first, the
/// raw payload one disclosure away. Shared by the session detail pane and the
/// dashboard inspector so both explain an event identically. `title` and
/// `body` are the sidecar's display text, so nothing is dug out of the JSON.
struct EventBodyView: View {
    let event: MonitorEvent
    @State private var fullText: FullEventText?
    /// Narrow inspector columns cut long bodies; a full-width pane scrolls
    /// instead and passes nil.
    var characterLimit: Int?
    var bodyFont: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = event.title, title != event.body {
                Text(title)
                    .font(bodyFont.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A request's outcome wins: a denied permission never reads "완료".
            if let status = event.stateLabel {
                Label(statusLine(status), systemImage: eventSymbol(event))
                    .font(.caption)
                    .foregroundStyle(eventColor(event))
            }
            if let input = event.detail["input"]?.stringValue, event.kind == "tool_call" {
                codeBlock(input, label: "입력")
            }
            if let body = event.body {
                if looksLikeCode(body) {
                    codeBlock(body, label: event.kind == "tool_call" ? "출력" : "본문")
                } else {
                    textBlock(body, font: bodyFont, label: "본문")
                }
            }
            if event.title != nil || event.body != nil {
                DisclosureGroup("원본 JSON") {
                    rawPayload.padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                rawPayload
            }
        }
        // Never wider than the column: a narrow inspector must be able to
        // shrink to it, and a vertical ScrollView keeps its bar at the trailing
        // edge only when its content actually fits that width.
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $fullText) { item in
            FullEventTextSheet(item: item)
        }
    }

    /// "완료 · 1.2초" when the event says how long it took.
    private func statusLine(_ status: String) -> String {
        guard let milliseconds = event.detail["durationMs"]?.doubleValue else { return status }
        return "\(status) · \(String(format: "%.1f", milliseconds / 1_000))초"
    }

    private var rawPayload: some View {
        codeBlock(event.payload.prettyPrinted, label: "JSON")
    }

    /// Prose: wraps to the available width, so it compresses with the column.
    private func textBlock(_ text: String, font: Font, label: String) -> some View {
        let shown = characterLimit.map { String(text.prefix($0)) } ?? text
        return VStack(alignment: .leading, spacing: 3) {
            Text(shown)
                .font(font)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            previewNote(shown: shown, full: text, label: label)
        }
    }

    /// Code / JSON: its long, unbroken lines would otherwise force the whole
    /// column wide (and push the scrollbar off-screen). Kept on its own lines
    /// and scrolled horizontally inside a width-bounded box instead of wrapping
    /// mid-token, so the column can still shrink to its minimum.
    private func codeBlock(_ text: String, label: String) -> some View {
        let shown = characterLimit.map { String(text.prefix($0)) } ?? text
        return VStack(alignment: .leading, spacing: 3) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(shown)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            previewNote(shown: shown, full: text, label: label)
        }
    }

    @ViewBuilder private func previewNote(shown: String, full: String, label: String) -> some View {
        if shown.count < full.count {
            HStack(spacing: 8) {
                Text("\(label) 미리보기 · 전체 \(full.count.formatted())자")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("전체 \(label) 보기…") {
                    fullText = FullEventText(title: "\(event.kindLabel) · \(label)", text: full)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
    }
}

struct FullEventText: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// The whole body a narrow inspector cut short: selectable, copyable.
private struct FullEventTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: FullEventText

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.title).font(.headline)
                Text("\(item.text.count.formatted())자").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("복사", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                }
                .help("전체 내용을 클립보드에 복사")
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(item.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 520)
    }
}

/// Tool output, diffs and JSON only stay readable with aligned columns; an
/// agent's prose does not, so it keeps the normal body font.
private func looksLikeCode(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("<") { return true }
    let lines = trimmed.split(separator: "\n")
    guard lines.count > 1 else { return false }
    let structured = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") || $0.hasPrefix("+") || $0.hasPrefix("-") }
    return structured.count * 2 >= lines.count
}

/// A session's token totals and context gauge, shown only for what the source
/// actually reports (every usage field is optional). Shared by the session
/// header and the dashboard inspector.
struct SessionUsageView: View {
    /// nil while a running turn has reported nothing yet.
    let usage: SessionUsage?
    /// The totals cover only the part of a long transcript that was read.
    var partial = false
    var forecast: UsageForecast?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let forecast { TurnForecastView(forecast: forecast) }
            if let usage { totals(usage) }
        }
        .help(ifPresent: partial ? "긴 대화 기록에서 읽은 부분만 합산한 값입니다." : nil)
    }

    @ViewBuilder private func totals(_ usage: SessionUsage) -> some View {
            if let total = usage.total {
                Text("세션 누적 토큰 \(formatTokenCount(total))\(partial ? "+" : "")")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                if let input = usage.inputTokens, let output = usage.outputTokens {
                    Text("입력(cache 포함) \(formatTokenCount(input)) · 출력 \(formatTokenCount(output))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let fraction = usage.contextFraction,
               let used = usage.contextUsed,
               let window = usage.contextWindow {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(contextColor(fraction))
                Text("최근 요청 컨텍스트 \(contextPercentText(fraction)) · \(formatTokenCount(used)) / \(formatTokenCount(window))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(contextPercentHelp)
            } else if let used = usage.contextUsed {
                // Claude reports the prompt size but not the window.
                Text("최근 요청 컨텍스트 \(formatTokenCount(used)) 토큰 (창 크기 미제공)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("최근 모델 요청에 들어간 토큰 수입니다. 이 데이터 출처는 컨텍스트 창 크기를 알려 주지 않습니다.")
            }
    }
}

/// "이번 턴 N 토큰 · 3분째" against the typical turn, and how many turns the
/// context has left at the recent rate. Shown only for what is known.
struct TurnForecastView: View {
    let forecast: UsageForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if forecast.currentTurnRunning {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green)
                    if let current = forecast.currentTurnTokens {
                        Text("이번 턴 \(formatTokenCount(current)) 토큰")
                    } else {
                        Text("이번 턴 집계 중")
                            .help("이 CLI는 턴이 끝날 때 토큰을 확정합니다.")
                    }
                    if let started = forecast.currentTurnStartedAt.flatMap(parseTimestamp) {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("· \(elapsedText(from: started, to: context.date))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .lineLimit(1)
                if let typical = forecast.typicalTurnTokens {
                    if let progress = forecast.progress {
                        ProgressView(value: min(progress, 1))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(progress > 1 ? .orange : .accentColor)
                    }
                    Text(forecastLine(typical: typical))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle((forecast.progress ?? 0) > 1 ? .orange : .secondary)
                        .lineLimit(1)
                        .help("완료된 최근 턴들이 쓴 토큰의 중앙값입니다. 이번 작업의 크기가 비슷하다면 이만큼 쓰게 됩니다.")
                }
            } else if let typical = forecast.typicalTurnTokens {
                Text("다음 턴 예상 약 \(formatTokenCount(typical)) 토큰 (지난 \(forecast.completedTurns)턴 중앙값)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let left = forecast.turnsUntilContextFull {
                Text(left == 0 ? "컨텍스트가 곧 가득 찹니다" : "컨텍스트 약 \(left)턴 여유")
                    .font(.caption2)
                    .foregroundStyle(left <= 2 ? .orange : .secondary)
                    .help("최근 턴마다 늘어난 컨텍스트 양으로 계산한 추정치입니다. 컨텍스트 압축이 일어나면 다시 늘어납니다.")
            }
        }
    }

    private func forecastLine(typical: Double) -> String {
        let base = "예상 약 \(formatTokenCount(typical)) (지난 \(forecast.completedTurns)턴 중앙값)"
        guard let progress = forecast.progressText else { return base }
        return "\(base) · \(progress)"
    }
}

/// "3분째", "1시간 5분째" for a running turn.
func elapsedText(from start: Date, to now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
    if minutes < 1 { return "방금 시작" }
    if minutes < 60 { return "\(minutes)분째" }
    return "\(minutes / 60)시간 \(minutes % 60)분째"
}

private struct SessionConfigRow: View {
    let option: SessionConfigOption
    let disabled: Bool
    let onSelect: (String) -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(option.name).font(.caption.weight(.medium)).frame(minWidth: 120, alignment: .leading)
            switch option.kind {
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { option.currentValue.boolValue ?? false },
                    set: onToggle
                ))
                .labelsHidden()
                .accessibilityLabel(option.name)
                .toggleStyle(.switch)
                .disabled(disabled)
            case let .select(choices):
                Picker("", selection: Binding(
                    get: { option.currentValue.stringValue ?? choices.first?.value ?? "" },
                    set: onSelect
                )) {
                    ForEach(choices) { choice in
                        Text(choice.groupName.map { "\($0) · \(choice.name)" } ?? choice.name).tag(choice.value)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(option.name)
                .disabled(disabled || choices.isEmpty)
                .frame(maxWidth: 220)
            case let .unknown(type):
                Text("지원되지 않는 설정 형식 (\(type))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(disabled || isUnknownType ? 0.72 : 1)
    }

    private var isUnknownType: Bool {
        if case .unknown = option.kind { return true }
        return false
    }
}
