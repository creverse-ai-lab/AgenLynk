import SwiftUI

/// What the sequence says when it has no rows, chosen by the caller (a
/// history session still loading, a source without a timeline, …).
struct SequenceEmptyState {
    var title = "표시할 이벤트가 없습니다"
    var symbol = "timeline.selection"
    var description = "세션 이벤트가 수신되면 호출 관계와 함께 표시됩니다."
    var loading = false
    /// "다시 시도" and what it does, for a failed load.
    var retry: (() -> Void)? = nil
}

struct EventSequenceView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var renamingSession: GatewaySession?
    let sessions: [GatewaySession]
    let events: [MonitorEvent]
    @Binding var selectedSessionId: String?
    @Binding var selectedEventId: String?
    /// True while the view sits at the newest event and follows new ones. It
    /// is driven by the scroll position: scrolling up stops following,
    /// scrolling back to the bottom (or "최신으로") resumes.
    @Binding var followLatestEvent: Bool
    /// Some session in view may have events older than the loaded ones.
    var canLoadOlder = false
    var loadingOlder = false
    /// Pages in older events; returns whether any arrived.
    var loadOlder: (() async -> Bool)?
    var emptyState = SequenceEmptyState()
    @State private var expandedGroups: Set<String> = []
    // Keyboard scrolling: the diagram is a 2-D canvas, so arrow keys step
    // through anchor points (one per row / per lane) and scroll to them.
    // Focus the diagram (click it) and the arrows move the view. The row is
    // kept by id, not index, so rows paged in above do not shift it.
    @State private var keyRowId: String?
    @State private var keyLane = 0
    @FocusState private var diagramFocused: Bool
    /// Set once the initial jump to the bottom has happened, so the top
    /// sentinel laid out on the first pass does not page older events in.
    @State private var settled = false
    @State private var topVisible = false
    @State private var olderRequestInFlight = false
    /// An automatic scroll to the bottom briefly hides the bottom sentinel;
    /// that must not read as the user scrolling away.
    @State private var lastAutoScroll = Date.distantPast

    private let timeWidth = 76.0
    private let laneWidth = 220.0
    private let headerHeight = 82.0
    private let eventRowHeight = 44.0
    private let childRowHeight = 34.0
    private let relationNodeSpacing = 8.0
    private static let bottomId = "sequence-bottom"

    var body: some View {
        timeline.sheet(item: $renamingSession) { session in
            SessionRenameSheet(session: session)
        }
    }

    @ViewBuilder private var timeline: some View {
        // Derived once per body pass. Events arrive whole (one message per
        // stream, one node per tool call); runs of tool calls in one turn
        // collapse into one representative row.
        let rows = EventTimeline.rows(EventTimeline.group(events), expanded: expandedGroups)
        let marks = sessionEventMarks()
        // One continuous timeline: every loaded row is in the same scroll, so
        // the lanes come from the loaded events themselves — a lane appears
        // for exactly the sessions that have a row somewhere in this scroll
        // (plus their parents), never for an unrelated older session.
        let lanes = makeSequenceLanes(sessions: sessions, events: events)
        let laneIndex = lanes.enumerated().reduce(into: [String: Int]()) { result, item in
            result[item.element.session.sessionId] = item.offset
        }
        let edges = lanes.compactMap { lane -> SequenceCallEdge? in
            guard let parentId = lane.parentSessionId,
                  let parentIndex = laneIndex[parentId],
                  let childIndex = laneIndex[lane.session.sessionId] else { return nil }
            let turnEndId = marks.lastTurnEndId[lane.session.sessionId]
            return SequenceCallEdge(
                parentIndex: parentIndex,
                childIndex: childIndex,
                child: lane.session,
                childDepth: lane.depth,
                eventId: marks.firstEventId[lane.session.sessionId],
                returnEventId: turnEndId,
                returned: hasReturned(lane.session, turnEndEventId: turnEndId)
            )
        }
        // The whole point of a sequence diagram: a call/응답 arrow is drawn on
        // the row of the event that triggered it — a call on the child's first
        // event, a 응답 on its turn_end — so the line sits at the moment it
        // happened on the shared time axis. A collapsed tool group carries the
        // arrows of the calls it stands for.
        let callAnchors = Dictionary(edges.compactMap { edge in edge.eventId.map { ($0, edge) } },
                                     uniquingKeysWith: { first, _ in first })
        let responseAnchors = Dictionary(edges.compactMap { edge in
            edge.returned ? edge.returnEventId.map { ($0, edge) } : nil
        }, uniquingKeysWith: { first, _ in first })
        let width = max(timeWidth + Double(max(lanes.count, 1)) * laneWidth, 620)

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("이벤트 \(events.count.formatted())개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if loadingOlder {
                    ProgressView().controlSize(.mini)
                    Text("이전 이벤트 불러오는 중").font(.caption2).foregroundStyle(.secondary)
                }
                Text("화살표: 호출 관계 · 노드: 이벤트 · 클릭 후 방향키로 이동")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if followLatestEvent {
                    Label("최신 따라가는 중", systemImage: "arrow.down.to.line")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("최신으로", systemImage: "arrow.down.to.line") {
                        scrollToBottom(proxy, animated: true)
                    }
                    .help("가장 최근 이벤트로 이동하고 새 이벤트를 따라갑니다")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()

            // Only the lane headers (provider / model / folder) are pinned —
            // that identity is what a reader loses when a long session scrolls.
            // The call/응답 arrows are not here; they live in the timeline below,
            // on the row of the event that triggered them. The single outer
            // horizontal scroll moves the headers with the body, so each header
            // stays over its own lifeline however far the diagram is panned.
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // One invisible anchor per lane, on the header row, so a
                        // left/right key scrolls horizontally without disturbing
                        // the vertical position.
                        ForEach(0..<max(lanes.count, 1), id: \.self) { index in
                            Color.clear.frame(width: 1, height: 1)
                                .id("col-\(index)")
                                .position(x: laneX(index), y: 6)
                        }
                        Canvas { context, _ in
                            // Lifeline stubs so the headers read as the top of
                            // the same lines the timeline below draws.
                            for (index, lane) in lanes.enumerated() {
                                let x = laneX(index)
                                var lifeline = Path()
                                lifeline.move(to: CGPoint(x: x, y: headerHeight - 8))
                                lifeline.addLine(to: CGPoint(x: x, y: headerHeight))
                                context.stroke(
                                    lifeline,
                                    with: .color(providerColor(lane.session.provider).opacity(0.34)),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])
                                )
                            }
                        }
                        .accessibilityHidden(true)

                        ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                            Button {
                                // Selecting a lane keeps the selected event.
                                selectedSessionId = lane.session.sessionId
                            } label: {
                                SequenceLaneHeader(
                                    lane: lane,
                                    selected: selectedSessionId == lane.session.sessionId
                                )
                            }
                                .buttonStyle(.plain)
                                .frame(width: laneWidth - 24, height: 64)
                                .position(x: laneX(index), y: 35)
                                .help("클릭해 이 세션 선택 · 우클릭으로 이름 바꾸기")
                                .contextMenu {
                                    Button("세션 상세 열기") { openWindow(id: "session-detail", value: lane.session.sessionId) }
                                    Button("이름 바꾸기…") { renamingSession = lane.session }
                                }
                        }
                    }
                    .frame(width: width, height: headerHeight)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .background(Color(nsColor: .controlBackgroundColor))

                    // One continuous, lazily built time axis, newest at the
                    // bottom. Each row draws its own slice of the lifelines and
                    // the arrows anchored on it, so a long timeline only lays
                    // out the rows on screen.
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            olderSentinel(rows: rows, proxy: proxy)
                                .frame(width: width, height: 24)

                            ForEach(rows) { row in
                                sequenceRow(
                                    row,
                                    lanes: lanes,
                                    laneIndex: laneIndex,
                                    callEdge: row.coveredEventIds.lazy.compactMap { callAnchors[$0] }.first,
                                    responseEdge: row.coveredEventIds.lazy.compactMap { responseAnchors[$0] }.first,
                                    width: width
                                )
                                .id(row.id)
                            }

                            if rows.isEmpty {
                                Group {
                                    if emptyState.loading {
                                        ProgressView(emptyState.title)
                                    } else {
                                        ContentUnavailableView {
                                            Label(emptyState.title, systemImage: emptyState.symbol)
                                        } description: {
                                            Text(emptyState.description)
                                        } actions: {
                                            if let retry = emptyState.retry {
                                                Button("다시 시도", action: retry)
                                            }
                                        }
                                    }
                                }
                                .frame(width: width, height: 240)
                            }

                            Color.clear
                                .frame(width: width, height: 12)
                                .id(Self.bottomId)
                                .onAppear { followLatestEvent = true }
                                .onDisappear {
                                    guard settled, Date().timeIntervalSince(lastAutoScroll) > 0.6 else { return }
                                    followLatestEvent = false
                                }
                        }
                        .padding(.horizontal, 10)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(maxHeight: .infinity)
                }
            }
            // Click to focus, then arrow keys scroll the diagram. onMoveCommand
            // fires on arrow presses only while this view holds focus, so it
            // never steals arrows from a focused list elsewhere.
            .focusable()
            .focused($diagramFocused)
            .onMoveCommand { direction in
                let last = max(0, rows.count - 1)
                let current = keyRowId.flatMap { id in rows.firstIndex { $0.id == id } }
                    ?? rows.firstIndex { $0.coveredEventIds.contains(selectedEventId ?? "") }
                    ?? last
                switch direction {
                case .up, .down:
                    let next = direction == .up ? max(0, current - 1) : min(last, current + 1)
                    if rows.indices.contains(next) {
                        keyRowId = rows[next].id
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rows[next].id, anchor: .center) }
                    }
                case .left:
                    keyLane = max(0, keyLane - 1)
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("col-\(keyLane)", anchor: .center) }
                case .right:
                    keyLane = min(max(0, lanes.count - 1), keyLane + 1)
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("col-\(keyLane)", anchor: .center) }
                @unknown default:
                    break
                }
            }
            // The newest event, not the newest row: a call joining the last tool
            // group keeps the row id but must still be followed.
            .onChange(of: events.last?.id) { _, _ in
                if followLatestEvent { scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: events.count) { _, _ in
                if followLatestEvent { scrollToBottom(proxy, animated: false) }
            }
            .task {
                // Let the default bottom anchor land before the top sentinel
                // may page anything in; a short timeline whose top is visible
                // from the start then fills itself once.
                try? await Task.sleep(nanoseconds: 700_000_000)
                settled = true
                if topVisible { requestOlder(rows: rows, proxy: proxy) }
            }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("이벤트 시퀀스. Frontdoor와 Worker의 호출·응답")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        lastAutoScroll = Date()
        followLatestEvent = true
        keyRowId = nil
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
    }

    /// The row above the first event: reaching it pages older events in.
    @ViewBuilder private func olderSentinel(rows: [TimelineRow], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            if canLoadOlder {
                if loadingOlder || olderRequestInFlight {
                    ProgressView().controlSize(.mini)
                    Text("이전 이벤트 불러오는 중").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("이전 이벤트 더 보기", systemImage: "arrow.up") { requestOlder(rows: rows, proxy: proxy, force: true) }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if !rows.isEmpty {
                Text("처음 이벤트").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            topVisible = true
            requestOlder(rows: rows, proxy: proxy)
        }
        .onDisappear { topVisible = false }
    }

    /// Loads the next older page and keeps the row that was on top in place,
    /// so the prepended events appear above it instead of shoving the view.
    private func requestOlder(rows: [TimelineRow], proxy: ScrollViewProxy, force: Bool = false) {
        guard force || settled, canLoadOlder, !olderRequestInFlight, let loadOlder else { return }
        // Anchor on an event, not a row: a tool group's row id changes when
        // older calls join it, and a vanished anchor would jump the view. An
        // expanded header covers no event, so its first call anchors.
        let anchorEventId = EventTimeline.anchorEventId(in: rows)
        olderRequestInFlight = true
        Task { @MainActor in
            let arrived = await loadOlder()
            olderRequestInFlight = false
            guard arrived, let anchorEventId else { return }
            await Task.yield()
            let refreshed = EventTimeline.rows(EventTimeline.group(events), expanded: expandedGroups)
            guard let rowId = EventTimeline.rowId(showing: anchorEventId, in: refreshed) else { return }
            proxy.scrollTo(rowId, anchor: .top)
        }
    }

    private func rowHeight(_ row: TimelineRow) -> Double {
        row.parentGroupId == nil ? eventRowHeight : childRowHeight
    }

    /// One row of the time axis: its slice of every lifeline, the arrows
    /// anchored on it, the time, and the node on its session's lane.
    @ViewBuilder private func sequenceRow(
        _ row: TimelineRow,
        lanes: [SequenceLane],
        laneIndex: [String: Int],
        callEdge: SequenceCallEdge?,
        responseEdge: SequenceCallEdge?,
        width: Double
    ) -> some View {
        let height = rowHeight(row)
        let y = height / 2
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for (index, lane) in lanes.enumerated() {
                    let x = laneX(index)
                    var lifeline = Path()
                    lifeline.move(to: CGPoint(x: x, y: 0))
                    lifeline.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(
                        lifeline,
                        with: .color(providerColor(lane.session.provider).opacity(0.34)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 5], dashPhase: 0)
                    )
                }
                // A call travels parent→child; a 응답 travels back, so its
                // head lands on the parent lane and its stroke is dashed.
                func drawArrow(_ edge: SequenceCallEdge, response: Bool) {
                    let parentX = laneX(edge.parentIndex)
                    let childX = laneX(edge.childIndex)
                    let from = response ? childX : parentX
                    let to = response ? parentX : childX
                    let color = providerColor(edge.child.provider)
                    var line = Path()
                    line.move(to: CGPoint(x: from, y: y))
                    line.addLine(to: CGPoint(x: to, y: y))
                    context.stroke(
                        line,
                        with: .color(color.opacity(response ? 0.6 : 0.72)),
                        style: response
                            ? StrokeStyle(lineWidth: 1.4, dash: [4, 3])
                            : StrokeStyle(lineWidth: 1.6)
                    )
                    context.stroke(
                        arrowHead(at: CGPoint(x: to, y: y), pointingRight: to >= from),
                        with: .color(color),
                        lineWidth: 1.6
                    )
                }
                if let callEdge { drawArrow(callEdge, response: false) }
                if let responseEdge { drawArrow(responseEdge, response: true) }
            }
            .accessibilityHidden(true)

            if row.parentGroupId == nil {
                Text(shortTime(row.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: timeWidth - 12, alignment: .trailing)
                    .position(x: (timeWidth - 12) / 2, y: y)
            }
            if let callEdge { relationCapsule(callEdge, response: false, y: y) }
            if let responseEdge { relationCapsule(responseEdge, response: true, y: y) }

            if let index = laneIndex[row.sessionId] {
                switch row.content {
                case let .event(event):
                    Button {
                        select(event)
                    } label: {
                        SequenceEventNode(
                            event: event,
                            selected: selectedEventId == event.id,
                            nested: row.parentGroupId != nil
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(width: row.parentGroupId == nil ? eventNodeWidth : eventNodeWidth - 16, height: height - 12)
                    .position(x: laneX(index) + (row.parentGroupId == nil ? 0 : 8), y: y)
                case let .group(group, expanded):
                    Button {
                        toggle(group)
                    } label: {
                        SequenceToolGroupNode(
                            group: group,
                            expanded: expanded,
                            selected: group.events.contains { $0.id == selectedEventId }
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(width: eventNodeWidth, height: height - 12)
                    .position(x: laneX(index), y: y)
                }
            }
        }
        .frame(width: width, height: height)
    }

    /// Expands or collapses a tool run; opening one also selects its
    /// representative call so the inspector shows what it is doing.
    private func toggle(_ group: ToolCallGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
            select(group.representative)
        }
    }

    /// Selecting an event also selects its session, so the selection strip
    /// and the inspector describe the same thing. The event goes first: the
    /// session change must find it already selected and keep it.
    private func select(_ event: MonitorEvent) {
        selectedEventId = event.id
        if selectedSessionId != event.sessionId { selectedSessionId = event.sessionId }
    }

    private func laneX(_ index: Int) -> Double {
        timeWidth + laneWidth * (Double(index) + 0.5)
    }

    private var eventNodeWidth: Double { laneWidth - 24 }

    private func relationCapsuleWidth(_ edge: SequenceCallEdge, response: Bool) -> Double {
        if response { return 58 }
        return edge.childDepth <= 1 ? 88 : 112
    }

    /// The label that sits on a call/응답 arrow at its anchoring event's row.
    /// Selecting it jumps to the arrow's own event (the call's first event, the
    /// 응답's turn_end) so the two stay tied together.
    @ViewBuilder private func relationCapsule(_ edge: SequenceCallEdge, response: Bool, y: Double) -> some View {
        let capsuleWidth = relationCapsuleWidth(edge, response: response)
        let capsuleX = SequenceRelationLayout.centerX(
            parentX: laneX(edge.parentIndex),
            childX: laneX(edge.childIndex),
            eventNodeWidth: eventNodeWidth,
            relationWidth: capsuleWidth,
            spacing: relationNodeSpacing
        )
        let eventId = response ? edge.returnEventId : edge.eventId
        Button {
            guard let eventId else { return }
            if let event = events.first(where: { $0.id == eventId }) {
                select(event)
            } else {
                selectedEventId = eventId
            }
        } label: {
            Label(response ? "응답" : edge.childDepthLabel, systemImage: response ? "arrow.uturn.left" : "arrow.right")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .frame(width: capsuleWidth)
                .padding(.vertical, 2)
                .background(.background, in: Capsule())
                .overlay(
                    Capsule().stroke(
                        providerColor(edge.child.provider).opacity(response ? 0.45 : 0.3),
                        style: response ? StrokeStyle(lineWidth: 1, dash: [3, 2]) : StrokeStyle(lineWidth: 1)
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(eventId == nil)
        .position(x: capsuleX, y: y)
        .help(
            response
                ? "\(edge.child.withModel(edge.child.providerLabel, separator: " ")) 응답"
                : "\(edge.child.withModel(edge.child.providerLabel, separator: " ")) \(edge.childDepthLabel)"
        )
        .accessibilityLabel(response ? "응답" : edge.childDepthLabel)
    }

    /// A worker counts as returned once it is no longer working *and* a turn
    /// actually finished for it: the gateway pushes `turn_end` at the end of a
    /// turn and stamps the same stopReason on the session record, so either
    /// signal alone is enough — `turn_end` may sit outside the loaded event
    /// window, and a restored session may carry a stopReason with no events.
    /// The isActive gate keeps a worker that is mid-turn (running /
    /// waiting_permission / waiting_input / cancelling / restoring) showing
    /// only its call arrow, which is what makes an unanswered call visible.
    private func hasReturned(_ session: GatewaySession, turnEndEventId: String?) -> Bool {
        guard !session.isActive else { return false }
        if turnEndEventId != nil { return true }
        return session.stopReason?.isEmpty == false
    }

    /// Earliest event id and newest `turn_end` id per session, in one grouping
    /// pass instead of a filter+sort of every event per edge.
    private func sessionEventMarks() -> SequenceEventMarks {
        var earliest: [String: MonitorEvent] = [:]
        var latestTurnEnd: [String: MonitorEvent] = [:]
        for event in events {
            if let current = earliest[event.sessionId] {
                if sequenceEventSort(event, current) { earliest[event.sessionId] = event }
            } else {
                earliest[event.sessionId] = event
            }
            guard event.kind == "turn_end" else { continue }
            if let current = latestTurnEnd[event.sessionId] {
                if sequenceEventSort(current, event) { latestTurnEnd[event.sessionId] = event }
            } else {
                latestTurnEnd[event.sessionId] = event
            }
        }
        return SequenceEventMarks(
            firstEventId: earliest.mapValues(\.id),
            lastTurnEndId: latestTurnEnd.mapValues(\.id)
        )
    }
}

private struct SequenceLane: Identifiable {
    let session: GatewaySession
    let parentSessionId: String?
    let depth: Int

    var id: String { session.sessionId }
}

private struct SequenceCallEdge: Identifiable {
    let parentIndex: Int
    let childIndex: Int
    let child: GatewaySession
    let childDepth: Int
    let eventId: String?
    let returnEventId: String?
    let returned: Bool

    var id: String { "call:\(child.sessionId)" }
    /// Every lane below the Frontdoor is a Worker; depth only qualifies it.
    var childDepthLabel: String { "Worker 호출" }
}

private struct SequenceEventMarks {
    let firstEventId: [String: String]
    let lastTurnEndId: [String: String]
}

/// Two-stroke arrowhead landing on `point`; `pointingRight` follows the travel
/// direction so call and return heads mirror each other.
private func arrowHead(at point: CGPoint, pointingRight: Bool) -> Path {
    let direction = pointingRight ? 1.0 : -1.0
    var arrow = Path()
    arrow.move(to: point)
    arrow.addLine(to: CGPoint(x: point.x - 7 * direction, y: point.y - 4))
    arrow.move(to: point)
    arrow.addLine(to: CGPoint(x: point.x - 7 * direction, y: point.y + 4))
    return arrow
}

private struct SequenceDiagramNode: Identifiable {
    let laneIndex: Int
    let event: MonitorEvent

    var id: String { event.id }
}

private struct SequenceLaneHeader: View {
    @EnvironmentObject private var settings: AppSettings
    let lane: SequenceLane
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                ProviderIcon(provider: lane.session.provider, size: 14)
                Text(roleLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 4) {
                // The session's own status, so a Worker waiting on a
                // permission shows on its lane, not only in the sidebar.
                Circle().fill(statusColor(lane.session.status)).frame(width: 6, height: 6)
                Text(settings.sessionName(lane.session))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120)
                if lane.session.isWaitingForUser {
                    Text(sessionStatusLabel(lane.session.status))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor(lane.session.status))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(settings.sessionName(lane.session)), \(sessionStatusLabel(lane.session.status))")
            if let model = lane.session.model {
                Text(model)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(7)
        .background(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Color.accentColor : providerColor(lane.session.provider).opacity(0.28), lineWidth: selected ? 2 : 1)
        )
    }

    private var roleLabel: String {
        if lane.session.isFrontdoorRecord { return frontdoorLabel }
        if lane.depth <= 1 { return "Worker" }
        return "Worker · \(lane.depth)단"
    }

    /// The user's chosen name when set, otherwise the working folder — stable
    /// and meaningful — falling back to a designated title only when there is
    /// no folder, and never to the transient tool-call text a local session
    /// parks in its title.
    private var frontdoorLabel: String {
        settings.frontdoorName(id: lane.session.openerInstanceId ?? "", auto: autoFrontdoorLabel)
    }

    private var autoFrontdoorLabel: String {
        let folder = (lane.session.cwd as NSString).lastPathComponent
        if !folder.isEmpty, folder != "/" { return folder }
        if let title = lane.session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let lower = title.lowercased()
            if !lower.contains("tool_call"), !lower.contains("function_call"), !title.contains("/") { return title }
        }
        return "Frontdoor"
    }
}

private struct SequenceEventNode: View {
    let event: MonitorEvent
    let selected: Bool
    /// A call shown under its expanded tool group.
    var nested = false

    var body: some View {
        HStack(spacing: 7) {
            // A tool call is a compact header — status glyph plus name and
            // the head of its argument; its output stays in the inspector.
            if event.kind == "tool_call", event.isInFlight {
                ProgressView().controlSize(.mini).frame(width: 15)
            } else {
                Image(systemName: eventSymbol(event))
                    .foregroundStyle(eventColor(event))
                    .frame(width: 15)
            }
            if event.kind == "tool_call", event.isHookObserved {
                HookMarker()
            }
            Text(event.headline)
                .font(nested ? .caption2 : .caption.weight(.semibold))
                .foregroundStyle(event.kind == "permission_request" ? eventColor(event) : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if event.kind != "tool_call", event.isInFlight {
                // A request still waiting on its answer.
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, nested ? 3 : 5)
        .background(selected ? Color.accentColor.opacity(0.16) : Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(selected ? Color.accentColor : Color.secondary.opacity(nested ? 0.12 : 0.2)))
        .help(event.kind == "tool_call" ? (event.title ?? event.summary) : event.summary)
    }
}

/// A run of tool calls as one node: count, the representative call (the
/// running one, else the latest), failures, and a chevron to expand.
private struct SequenceToolGroupNode: View {
    let group: ToolCallGroup
    let expanded: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 9)
            if group.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(group.failedCount > 0 ? .red : .cyan)
            }
            if group.isHookObserved { HookMarker() }
            Text(group.summary(titleLimit: 18))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(selected ? Color.accentColor : Color.cyan.opacity(0.35)))
        .help(group.summary(titleLimit: 60) + (expanded ? " · 도구 호출 \(group.events.count)개 접기" : " · 도구 호출 \(group.events.count)개 펼치기"))
    }
}

private func makeSequenceLanes(sessions: [GatewaySession], events: [MonitorEvent]) -> [SequenceLane] {
    let byId = sessions.reduce(into: [String: GatewaySession]()) { result, session in
        result[session.sessionId] = session
    }
    let rootsByOpener = sessions.filter(\.isFrontdoorRecord).reduce(into: [String: GatewaySession]()) { result, session in
        guard let opener = session.openerInstanceId else { return }
        result[opener] = session
    }

    func parentId(for session: GatewaySession) -> String? {
        if let explicit = session.parentSessionId, byId[explicit] != nil { return explicit }
        guard !session.isFrontdoorRecord,
              let opener = session.openerInstanceId,
              let root = rootsByOpener[opener],
              root.sessionId != session.sessionId else { return nil }
        return root.sessionId
    }

    var included = Set(events.map(\.sessionId))
    var pending = Array(included)
    while let id = pending.popLast(), let session = byId[id], let parent = parentId(for: session) {
        if included.insert(parent).inserted { pending.append(parent) }
    }

    let members = included.compactMap { byId[$0] }
    let memberIds = Set(members.map(\.sessionId))
    var children: [String: [GatewaySession]] = [:]
    var roots: [GatewaySession] = []
    for session in members {
        if let parent = parentId(for: session), memberIds.contains(parent) {
            children[parent, default: []].append(session)
        } else {
            roots.append(session)
        }
    }

    let sessionOrder: (GatewaySession, GatewaySession) -> Bool = {
        ($0.createdAt ?? "") < ($1.createdAt ?? "")
    }
    var lanes: [SequenceLane] = []
    var visited = Set<String>()
    func append(_ session: GatewaySession, depth: Int, parent: String?) {
        guard visited.insert(session.sessionId).inserted else { return }
        lanes.append(SequenceLane(session: session, parentSessionId: parent, depth: depth))
        for child in (children[session.sessionId] ?? []).sorted(by: sessionOrder) {
            append(child, depth: depth + 1, parent: session.sessionId)
        }
    }
    for root in roots.sorted(by: sessionOrder) { append(root, depth: 0, parent: nil) }
    for session in members.sorted(by: sessionOrder) where !visited.contains(session.sessionId) {
        append(session, depth: 0, parent: nil)
    }
    return lanes
}

// Delegates to the canonical within-session ordering in Models.swift; the
// call sites here compare events of one session at a time.
private func sequenceEventSort(_ left: MonitorEvent, _ right: MonitorEvent) -> Bool {
    withinSessionEventOrder(left, right)
}
