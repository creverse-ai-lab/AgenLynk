import SwiftUI

struct EventSequenceView: View {
    let sessions: [GatewaySession]
    let events: [MonitorEvent]
    @Binding var selectedSessionId: String?
    @Binding var selectedEventId: String?
    @Binding var followLatestEvent: Bool
    @State private var page = 0

    private let pageSize = 20
    private let timeWidth = 76.0
    private let laneWidth = 220.0
    private let headerHeight = 82.0
    private let eventRowHeight = 44.0
    private let bodyTopInset = 10.0

    var body: some View {
        // Derived once per body pass. The computed-property forms re-ran
        // collapseSequenceEvents up to four times (totalPages, pageEvents,
        // pageRangeLabel, onChange) and firstEventId filtered+sorted the full
        // event array once per edge — measurable milliseconds at 10 passes/s
        // during a busy turn.
        let diagram = collapseSequenceEvents(events)
        let marks = sessionEventMarks()
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
        let nodes = pageEvents(in: diagram).compactMap { entry -> SequenceDiagramNode? in
            guard let index = laneIndex[entry.event.sessionId] else { return nil }
            return SequenceDiagramNode(laneIndex: index, event: entry.event, collapsedCount: entry.count)
        }
        // The whole point of a sequence diagram: a call/응답 arrow is drawn on
        // the row of the event that triggered it — a call on the child's first
        // visible event, a 응답 on its turn_end — so the line sits at the moment
        // it happened on the shared time axis, next to that event, instead of
        // floating in a separate band that read as unrelated to the timeline.
        let callAnchors = Dictionary(edges.compactMap { edge in edge.eventId.map { ($0, edge) } },
                                     uniquingKeysWith: { first, _ in first })
        let responseAnchors = Dictionary(edges.compactMap { edge in
            edge.returned ? edge.returnEventId.map { ($0, edge) } : nil
        }, uniquingKeysWith: { first, _ in first })
        let rowY = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { row, node in
            (node.event.id, bodyTopInset + Double(row) * eventRowHeight + eventRowHeight / 2)
        })
        let width = max(timeWidth + Double(max(lanes.count, 1)) * laneWidth, 620)
        let bodyHeight = max(bodyTopInset + Double(max(nodes.count, 1)) * eventRowHeight + 16, 240)
        let pages = max(1, (diagram.count + pageSize - 1) / pageSize)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(pageRangeLabel(for: diagram))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("화살표: 호출 관계 · 노드: 이벤트")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    followLatestEvent.toggle()
                    if followLatestEvent { page = 0 }
                } label: {
                    Label(
                        followLatestEvent ? "최신 따라가는 중" : "최신 따라가기",
                        systemImage: followLatestEvent ? "pause.circle.fill" : "play.circle"
                    )
                }
                .foregroundStyle(followLatestEvent ? .green : .secondary)
                Button("이전 로그", systemImage: "chevron.left") {
                    followLatestEvent = false
                    page += 1
                }
                    .disabled(page + 1 >= pages)
                Button("최신 로그", systemImage: "chevron.right") { page = 0 }
                    .disabled(page == 0)
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
                                followLatestEvent = false
                                selectedSessionId = lane.session.sessionId
                                selectedEventId = nil
                            } label: {
                                SequenceLaneHeader(
                                    lane: lane,
                                    selected: selectedSessionId == lane.session.sessionId
                                )
                            }
                                .buttonStyle(.plain)
                                .frame(width: laneWidth - 24, height: 64)
                                .position(x: laneX(index), y: 35)
                                .help("\(lane.session.provider) \(lane.session.model ?? "default") 세션 상세")
                        }
                    }
                    .frame(width: width, height: headerHeight)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .background(Color(nsColor: .controlBackgroundColor))

                    // One scrolling time axis: lifelines, event nodes, and the
                    // call/응답 arrows that connect them all share it, so an
                    // arrow lands on the same row as the event that caused it.
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            Canvas { context, _ in
                                for (index, lane) in lanes.enumerated() {
                                    let x = laneX(index)
                                    var lifeline = Path()
                                    lifeline.move(to: CGPoint(x: x, y: 0))
                                    lifeline.addLine(to: CGPoint(x: x, y: bodyHeight))
                                    context.stroke(
                                        lifeline,
                                        with: .color(providerColor(lane.session.provider).opacity(0.34)),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])
                                    )
                                }

                                // A call travels parent→child; a 응답 travels
                                // back, so its head lands on the parent lane and
                                // its stroke is dashed. Both are drawn at the y
                                // of their anchoring event.
                                func drawArrow(_ edge: SequenceCallEdge, y: Double, response: Bool) {
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
                                for node in nodes {
                                    guard let y = rowY[node.event.id] else { continue }
                                    if let edge = callAnchors[node.event.id] { drawArrow(edge, y: y, response: false) }
                                    if let edge = responseAnchors[node.event.id] { drawArrow(edge, y: y, response: true) }
                                }
                            }
                            .accessibilityHidden(true)

                            ForEach(Array(nodes.enumerated()), id: \.element.id) { row, node in
                                let y = bodyTopInset + Double(row) * eventRowHeight + eventRowHeight / 2
                                Text(shortTime(node.event.timestamp))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: timeWidth - 12, alignment: .trailing)
                                    .position(x: (timeWidth - 12) / 2, y: y)
                                if let edge = callAnchors[node.event.id] {
                                    relationCapsule(edge, response: false, y: y)
                                }
                                if let edge = responseAnchors[node.event.id] {
                                    relationCapsule(edge, response: true, y: y)
                                }
                                Button {
                                    followLatestEvent = false
                                    selectedEventId = node.event.id
                                } label: {
                                    SequenceEventNode(
                                        event: node.event,
                                        collapsedCount: node.collapsedCount,
                                        selected: selectedEventId == node.event.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(width: laneWidth - 24, height: eventRowHeight - 12)
                                .position(x: laneX(node.laneIndex), y: y)
                            }

                            if nodes.isEmpty {
                                ContentUnavailableView(
                                    "표시할 이벤트가 없습니다",
                                    systemImage: "timeline.selection",
                                    description: Text("세션 이벤트가 수신되면 호출 관계와 함께 표시됩니다.")
                                )
                                .frame(width: width, height: bodyHeight)
                            }
                        }
                        .frame(width: width, height: bodyHeight)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Frontdoor Agent Subagent 이벤트 시퀀스 다이어그램")
        .onChange(of: diagram.count) { _, _ in
            if followLatestEvent {
                page = 0
            } else {
                page = min(page, max(pages - 1, 0))
            }
        }
    }

    private func laneX(_ index: Int) -> Double {
        timeWidth + laneWidth * (Double(index) + 0.5)
    }

    /// The label that sits on a call/응답 arrow at its anchoring event's row.
    /// Selecting it jumps to the arrow's own event (the call's first event, the
    /// 응답's turn_end) so the two stay tied together.
    @ViewBuilder private func relationCapsule(_ edge: SequenceCallEdge, response: Bool, y: Double) -> some View {
        let midX = (laneX(edge.parentIndex) + laneX(edge.childIndex)) / 2
        let eventId = response ? edge.returnEventId : edge.eventId
        Button {
            followLatestEvent = false
            if let eventId { selectedEventId = eventId }
        } label: {
            Label(response ? "응답" : edge.childDepthLabel, systemImage: response ? "arrow.uturn.left" : "arrow.right")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
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
        .position(x: midX, y: y)
        .help(
            response
                ? "\(edge.child.provider) \(edge.child.model ?? "default") 응답 반환"
                : "\(edge.child.provider) \(edge.child.model ?? "default") 호출"
        )
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
            guard event.type == "turn_end" else { continue }
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

    private func pageEvents(in values: [SequenceEventEntry]) -> ArraySlice<SequenceEventEntry> {
        let end = max(0, values.count - page * pageSize)
        let start = max(0, end - pageSize)
        return values[start..<end]
    }

    private func pageRangeLabel(for values: [SequenceEventEntry]) -> String {
        guard !values.isEmpty else { return "0 / 0" }
        let end = max(0, values.count - page * pageSize)
        let start = max(0, end - pageSize)
        return "\(start + 1)–\(end) / \(values.count)"
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
    var childDepthLabel: String { childDepth <= 1 ? "Agent 호출" : "Subagent 호출" }
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
    let collapsedCount: Int

    var id: String { event.id }
}

private struct SequenceLaneHeader: View {
    @EnvironmentObject private var settings: AppSettings
    let lane: SequenceLane
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(providerColor(lane.session.provider)).frame(width: 7, height: 7)
                Text(roleLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(lane.session.provider.capitalized)
                .font(.caption2.weight(.medium))
            Text(lane.session.model ?? "default")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        if lane.depth <= 1 { return "Agent" }
        return "Subagent L\(lane.depth)"
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
    let collapsedCount: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: eventSymbol(event.type))
                .foregroundStyle(eventColor(event.type))
                .frame(width: 15)
            Text(event.type == "agent_message_chunk" ? "agent response" : event.type.replacingOccurrences(of: "_", with: " "))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if collapsedCount > 1 {
                Text("×\(collapsedCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.16) : Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2)))
        .help(event.summary)
    }
}

private struct SequenceEventEntry {
    var event: MonitorEvent
    var count: Int
}

private func collapseSequenceEvents(_ events: [MonitorEvent]) -> [SequenceEventEntry] {
    var result: [SequenceEventEntry] = []
    result.reserveCapacity(events.count)
    for event in events {
        // Thought chunks stream in runs exactly like message chunks now that
        // delegated workers request thinking output.
        if event.type == "agent_message_chunk" || event.type == "agent_thought_chunk",
           let last = result.last,
           last.event.type == event.type,
           last.event.sessionId == event.sessionId,
           last.event.turnId == event.turnId {
            result[result.count - 1] = SequenceEventEntry(event: event, count: last.count + 1)
        } else {
            result.append(SequenceEventEntry(event: event, count: 1))
        }
    }
    return result
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
