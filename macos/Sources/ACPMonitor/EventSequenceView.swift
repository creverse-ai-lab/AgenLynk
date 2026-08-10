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
    private let relationRowHeight = 26.0
    private let eventRowHeight = 44.0

    var body: some View {
        // Derived once per body pass. The computed-property forms re-ran
        // collapseSequenceEvents up to four times (totalPages, pageEvents,
        // pageRangeLabel, onChange) and firstEventId filtered+sorted the full
        // event array once per edge — measurable milliseconds at 10 passes/s
        // during a busy turn.
        let diagram = collapseSequenceEvents(events)
        let firstEventBySession = firstEventIds()
        let lanes = makeSequenceLanes(sessions: sessions, events: events)
        let laneIndex = lanes.enumerated().reduce(into: [String: Int]()) { result, item in
            result[item.element.session.sessionId] = item.offset
        }
        let edges = lanes.compactMap { lane -> SequenceCallEdge? in
            guard let parentId = lane.parentSessionId,
                  let parentIndex = laneIndex[parentId],
                  let childIndex = laneIndex[lane.session.sessionId] else { return nil }
            return SequenceCallEdge(
                parentIndex: parentIndex,
                childIndex: childIndex,
                child: lane.session,
                childDepth: lane.depth,
                eventId: firstEventBySession[lane.session.sessionId]
            )
        }
        let nodes = pageEvents(in: diagram).compactMap { entry -> SequenceDiagramNode? in
            guard let index = laneIndex[entry.event.sessionId] else { return nil }
            return SequenceDiagramNode(laneIndex: index, event: entry.event, collapsedCount: entry.count)
        }
        let relationHeight = max(Double(edges.count) * relationRowHeight, 12)
        let eventTop = headerHeight + relationHeight + 8
        let width = max(timeWidth + Double(max(lanes.count, 1)) * laneWidth, 620)
        let height = max(eventTop + Double(max(nodes.count, 1)) * eventRowHeight + 20, 420)
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

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for (index, lane) in lanes.enumerated() {
                            let x = laneX(index)
                            var lifeline = Path()
                            lifeline.move(to: CGPoint(x: x, y: headerHeight - 8))
                            lifeline.addLine(to: CGPoint(x: x, y: height - 12))
                            context.stroke(
                                lifeline,
                                with: .color(providerColor(lane.session.provider).opacity(0.34)),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])
                            )
                        }

                        for (index, edge) in edges.enumerated() {
                            let parentX = laneX(edge.parentIndex)
                            let childX = laneX(edge.childIndex)
                            let y = headerHeight + Double(index) * relationRowHeight + relationRowHeight / 2
                            var call = Path()
                            call.move(to: CGPoint(x: parentX, y: y))
                            call.addLine(to: CGPoint(x: childX, y: y))
                            context.stroke(call, with: .color(providerColor(edge.child.provider).opacity(0.72)), lineWidth: 1.6)

                            let direction = childX >= parentX ? 1.0 : -1.0
                            var arrow = Path()
                            arrow.move(to: CGPoint(x: childX, y: y))
                            arrow.addLine(to: CGPoint(x: childX - 7 * direction, y: y - 4))
                            arrow.move(to: CGPoint(x: childX, y: y))
                            arrow.addLine(to: CGPoint(x: childX - 7 * direction, y: y + 4))
                            context.stroke(arrow, with: .color(providerColor(edge.child.provider)), lineWidth: 1.6)
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

                    ForEach(Array(edges.enumerated()), id: \.element.id) { index, edge in
                        let parentX = laneX(edge.parentIndex)
                        let childX = laneX(edge.childIndex)
                        let y = headerHeight + Double(index) * relationRowHeight + relationRowHeight / 2
                        Button {
                            followLatestEvent = false
                            if let eventId = edge.eventId { selectedEventId = eventId }
                        } label: {
                            Label(edge.childDepthLabel, systemImage: "arrow.right")
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.background, in: Capsule())
                                .overlay(Capsule().stroke(providerColor(edge.child.provider).opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .disabled(edge.eventId == nil)
                        .position(x: (parentX + childX) / 2, y: y)
                        .help("\(edge.child.provider) \(edge.child.model ?? "default") 호출")
                    }

                    ForEach(Array(nodes.enumerated()), id: \.element.id) { row, node in
                        let y = eventTop + Double(row) * eventRowHeight + eventRowHeight / 2
                        Text(shortTime(node.event.timestamp))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: timeWidth - 12, alignment: .trailing)
                            .position(x: (timeWidth - 12) / 2, y: y)
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
                        .frame(width: width, height: height)
                    }
                }
                .frame(width: width, height: height)
                .padding(10)
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

    /// Earliest event id per session, in one grouping pass instead of a
    /// filter+sort of every event per edge.
    private func firstEventIds() -> [String: String] {
        var earliest: [String: MonitorEvent] = [:]
        for event in events {
            if let current = earliest[event.sessionId] {
                if sequenceEventSort(event, current) { earliest[event.sessionId] = event }
            } else {
                earliest[event.sessionId] = event
            }
        }
        return earliest.mapValues(\.id)
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

    var id: String { "call:\(child.sessionId)" }
    var childDepthLabel: String { childDepth <= 1 ? "Agent 호출" : "Subagent 호출" }
}

private struct SequenceDiagramNode: Identifiable {
    let laneIndex: Int
    let event: MonitorEvent
    let collapsedCount: Int

    var id: String { event.id }
}

private struct SequenceLaneHeader: View {
    let lane: SequenceLane
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(providerColor(lane.session.provider)).frame(width: 7, height: 7)
                Text(roleLabel).font(.caption.weight(.semibold))
            }
            Text(lane.session.provider.capitalized)
                .font(.caption2.weight(.medium))
            Text(lane.session.sourceLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(lane.session.isLocalSource ? .purple : .blue)
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
        if lane.session.isFrontdoorRecord { return "Frontdoor" }
        if lane.depth <= 1 { return "Agent" }
        return "Subagent L\(lane.depth)"
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
        if event.type == "agent_message_chunk",
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

private func sequenceEventSort(_ left: MonitorEvent, _ right: MonitorEvent) -> Bool {
    if let leftSequence = left.sequence, let rightSequence = right.sequence, leftSequence != rightSequence {
        return leftSequence < rightSequence
    }
    return (left.timestamp ?? "") < (right.timestamp ?? "")
}
