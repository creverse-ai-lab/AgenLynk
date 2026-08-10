import Foundation

struct GraphGroup: Identifiable, Sendable {
    let id: String
    let opener: String
    let cwd: String
    let trunkX: Double
}

struct GraphLane: Identifiable, Sendable {
    let id: String
    let session: GatewaySession
    let trunkX: Double
    let laneX: Double
    let turns: [GraphTurnPoint]
}

struct GraphTurnPoint: Identifiable, Sendable {
    let id: String
    let turnId: String?
    let prompt: String
    let response: String
    let startedAt: String?
    let completed: Bool
    let failed: Bool
    let progress: Double
    let events: [MonitorEvent]

    var promptPreview: String {
        String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(44))
    }
}

struct GraphProjection: Sendable {
    let groups: [GraphGroup]
    let lanes: [GraphLane]
    let width: Double

    /// Lanes flattened into a single top-to-bottom reading order: each group's
    /// Frontdoor root first, then its workers. The window graph gets this
    /// ordering for free from its X layout; a stacked lane list has to ask for
    /// it explicitly.
    var lanesOrderedByTrunk: [GraphLane] {
        groups
            .sorted { $0.trunkX < $1.trunkX }
            .flatMap { group in
                lanes
                    .filter { $0.trunkX == group.trunkX }
                    .sorted { lhs, rhs in
                        if lhs.session.isFrontdoorRecord != rhs.session.isFrontdoorRecord {
                            return lhs.session.isFrontdoorRecord
                        }
                        return lhs.laneX < rhs.laneX
                    }
            }
    }

    var turnCount: Int { lanes.reduce(0) { $0 + $1.turns.count } }
    var activeTurnCount: Int { lanes.reduce(0) { $0 + $1.turns.filter { !$0.completed }.count } }
    var workerLaneCount: Int { lanes.filter { !$0.session.isFrontdoorRecord }.count }

    private static let maxTurns = 120
    private static let maxEventsPerTurn = 160
    private static let maxPromptCharacters = 4_000
    private static let maxResponseCharacters = 12_000

    /// Projects what is running *right now*: each active session contributes its
    /// current turn and nothing else. There is no history window — the popover
    /// is the only renderer, and it shows live work.
    static func make(
        sessions: [GatewaySession],
        eventsBySession: [String: [MonitorEvent]]
    ) -> GraphProjection {
        var turnsBySession: [String: [GraphTurnPoint]] = [:]
        for session in sessions {
            let scoped = currentTurnEvents(
                eventsBySession[session.sessionId] ?? [],
                activeTurnId: session.isActive ? session.turnId : nil
            )
            turnsBySession[session.sessionId] = makeTurns(events: scoped)
        }

        let pinnedTurnIds = Set(sessions.compactMap { session -> String? in
            guard session.isActive, let turnId = session.turnId else { return nil }
            return turnsBySession[session.sessionId]?.first(where: { $0.turnId == turnId })?.id
        })
        let allOrderedTurns = turnsBySession.values.flatMap { $0 }.sorted(by: turnOrder)
        var visibleTurnIds = Set(allOrderedTurns.suffix(maxTurns).map(\.id))
        visibleTurnIds.formUnion(pinnedTurnIds)
        for sessionId in Array(turnsBySession.keys) {
            turnsBySession[sessionId] = turnsBySession[sessionId]?.filter { visibleTurnIds.contains($0.id) }
        }
        let relevantSessions = sessions.filter { session in
            session.isActive || !(turnsBySession[session.sessionId] ?? []).isEmpty
        }

        let orderedTurns = turnsBySession.values.flatMap { $0 }.sorted(by: turnOrder)
        var progressByTurn: [String: Double] = [:]
        for (index, turn) in orderedTurns.enumerated() {
            let progress: Double
            if orderedTurns.count == 1 {
                progress = 0.5
            } else {
                progress = 0.1 + (0.8 * Double(index) / Double(orderedTurns.count - 1))
            }
            progressByTurn[turn.id] = progress
        }

        let grouped = Dictionary(grouping: relevantSessions) {
            $0.openerInstanceId ?? "legacy:\($0.opener ?? "unknown")|\($0.cwd)"
        }
        let sortedGroups = grouped.sorted { $0.key < $1.key }
        var groups: [GraphGroup] = []
        var lanes: [GraphLane] = []
        var x = 70.0

        for (key, groupSessions) in sortedGroups {
            let first = groupSessions.first(where: \.isFrontdoorRecord) ?? groupSessions.first!
            let trunkX = x
            groups.append(GraphGroup(id: key, opener: first.opener ?? "Frontdoor", cwd: first.cwd, trunkX: trunkX))
            x += 42
            for session in groupSessions.sorted(by: { $0.createdAt ?? "" < $1.createdAt ?? "" }) {
                let turns = (turnsBySession[session.sessionId] ?? []).map { turn in
                    GraphTurnPoint(
                        id: turn.id,
                        turnId: turn.turnId,
                        prompt: turn.prompt,
                        response: turn.response,
                        startedAt: turn.startedAt,
                        completed: turn.completed,
                        failed: turn.failed,
                        progress: progressByTurn[turn.id] ?? 0.5,
                        events: turn.events
                    )
                }
                lanes.append(GraphLane(id: session.sessionId, session: session, trunkX: trunkX, laneX: x, turns: turns))
                x += 210
            }
            x += 64
        }
        return GraphProjection(groups: groups, lanes: lanes, width: max(x, 760))
    }

    private static func currentTurnEvents(_ events: [MonitorEvent], activeTurnId: String?) -> [MonitorEvent] {
        guard let activeTurnId else { return [] }
        // Live may receive thousands of token chunks. Walk backwards and retain only
        // the detail budget instead of filtering/copying the entire session on every chunk.
        var recent: [MonitorEvent] = []
        recent.reserveCapacity(maxEventsPerTurn)
        var startEvent: MonitorEvent?
        for event in events.reversed() where event.turnId == activeTurnId {
            if event.type == "turn_start" {
                startEvent = event
                break
            }
            if recent.count < maxEventsPerTurn - 1 { recent.append(event) }
        }
        recent.reverse()
        if let startEvent { recent.insert(startEvent, at: 0) }
        return recent.sorted(by: eventOrder)
    }

    private static func makeTurns(events: [MonitorEvent]) -> [GraphTurnPoint] {
        let sorted = events.sorted {
            eventOrder($0, $1)
        }
        var turns: [GraphTurnPoint] = []
        var current: TurnAccumulator?

        func finishCurrent() {
            if let current { turns.append(current.value) }
            current = nil
        }

        for event in sorted {
            if event.type == "turn_start" {
                finishCurrent()
                current = TurnAccumulator(
                    id: event.id,
                    turnId: event.turnId,
                    prompt: boundedPrefix(event.text ?? "(prompt 내용 없음)", limit: maxPromptCharacters),
                    startedAt: event.timestamp,
                    events: [event]
                )
                continue
            }
            guard let turn = current else { continue }
            turn.append(event, limit: maxEventsPerTurn)
            switch event.type {
            case "agent_message_chunk":
                turn.appendResponse(event.text ?? "", limit: maxResponseCharacters)
            case "tool_call", "permission_request", "elicitation_request":
                // Gateway의 최종 result와 동일하게 마지막 경계 이후의 메시지만 남긴다.
                turn.clearResponse()
            case "turn_end":
                turn.completed = true
                finishCurrent()
                continue
            case "error":
                if let text = event.text { turn.replaceResponse(text, limit: maxResponseCharacters) }
                turn.completed = true
                turn.failed = true
                finishCurrent()
                continue
            default:
                break
            }
        }
        finishCurrent()
        return turns
    }

    private static func turnOrder(_ lhs: GraphTurnPoint, _ rhs: GraphTurnPoint) -> Bool {
        if lhs.startedAt != rhs.startedAt { return (lhs.startedAt ?? "") < (rhs.startedAt ?? "") }
        return lhs.id < rhs.id
    }

    private static func eventOrder(_ lhs: MonitorEvent, _ rhs: MonitorEvent) -> Bool {
        // Canonical within-session ordering (Models.swift); lanes are scoped
        // to a single session's events.
        withinSessionEventOrder(lhs, rhs)
    }

    private static func boundedPrefix(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    private static func boundedSuffix(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return "…" + String(value.suffix(limit))
    }

    private final class TurnAccumulator {
        let id: String
        let turnId: String?
        let prompt: String
        let startedAt: String?
        var response = ""
        var responseCharacters = 0
        var completed = false
        var failed = false
        var events: [MonitorEvent]

        init(id: String, turnId: String?, prompt: String, startedAt: String?, events: [MonitorEvent]) {
            self.id = id
            self.turnId = turnId
            self.prompt = prompt
            self.startedAt = startedAt
            self.events = events
        }

        func append(_ event: MonitorEvent, limit: Int) {
            if events.count >= limit, events.count > 1 { events.remove(at: 1) }
            events.append(event)
        }

        func appendResponse(_ text: String, limit: Int) {
            guard !text.isEmpty else { return }
            response += text
            responseCharacters += text.count
            if responseCharacters > limit {
                response = GraphProjection.boundedSuffix(response, limit: limit)
                responseCharacters = response.count
            }
        }

        func clearResponse() {
            response = ""
            responseCharacters = 0
        }

        func replaceResponse(_ text: String, limit: Int) {
            response = GraphProjection.boundedSuffix(text, limit: limit)
            responseCharacters = response.count
        }

        var value: GraphTurnPoint {
            GraphTurnPoint(
                id: id,
                turnId: turnId,
                prompt: prompt,
                response: response,
                startedAt: startedAt,
                completed: completed,
                failed: failed,
                progress: 0,
                events: events
            )
        }
    }
}
