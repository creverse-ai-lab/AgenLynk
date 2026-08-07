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

    var promptPreview: String {
        String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(44))
    }
}

struct GraphProjection: Sendable {
    let groups: [GraphGroup]
    let lanes: [GraphLane]
    let width: Double

    var turnCount: Int { lanes.reduce(0) { $0 + $1.turns.count } }
    var activeTurnCount: Int { lanes.reduce(0) { $0 + $1.turns.filter { !$0.completed }.count } }

    static func make(
        sessions: [GatewaySession],
        eventsBySession: [String: [MonitorEvent]],
        windowMinutes: Int,
        now: Date = Date()
    ) -> GraphProjection {
        let start = now.addingTimeInterval(-Double(windowMinutes * 60))
        let turnsBySession = Dictionary(uniqueKeysWithValues: sessions.map { session in
            let turns = makeTurns(events: eventsBySession[session.sessionId] ?? []).filter { turn in
                guard let raw = turn.startedAt, let date = parseTimestamp(raw) else { return session.isActive }
                return date >= start
            }
            return (session.sessionId, turns)
        })
        let relevantSessions = sessions.filter { session in
            session.isActive || !(turnsBySession[session.sessionId] ?? []).isEmpty
        }

        let orderedTurns = turnsBySession.values.flatMap { $0 }.sorted(by: turnOrder)
        let progressByTurn = Dictionary(uniqueKeysWithValues: orderedTurns.enumerated().map { index, turn in
            let progress: Double
            if orderedTurns.count == 1 {
                progress = 0.5
            } else {
                progress = 0.1 + (0.8 * Double(index) / Double(orderedTurns.count - 1))
            }
            return (turn.id, progress)
        })

        let grouped = Dictionary(grouping: relevantSessions) {
            $0.openerInstanceId ?? "legacy:\($0.opener ?? "unknown")|\($0.cwd)"
        }
        let sortedGroups = grouped.sorted { $0.key < $1.key }
        var groups: [GraphGroup] = []
        var lanes: [GraphLane] = []
        var x = 70.0

        for (key, groupSessions) in sortedGroups {
            let first = groupSessions.first!
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
                        progress: progressByTurn[turn.id] ?? 0.5
                    )
                }
                lanes.append(GraphLane(id: session.sessionId, session: session, trunkX: trunkX, laneX: x, turns: turns))
                x += 210
            }
            x += 64
        }
        return GraphProjection(groups: groups, lanes: lanes, width: max(x, 760))
    }

    private static func makeTurns(events: [MonitorEvent]) -> [GraphTurnPoint] {
        let sorted = events.sorted {
            if ($0.sequence ?? Int.max) != ($1.sequence ?? Int.max) {
                return ($0.sequence ?? Int.max) < ($1.sequence ?? Int.max)
            }
            return ($0.timestamp ?? "") < ($1.timestamp ?? "")
        }
        var turns: [GraphTurnPoint] = []
        var current: GraphTurnPoint?

        func finishCurrent() {
            if let current { turns.append(current) }
            current = nil
        }

        for event in sorted {
            if event.type == "turn_start" {
                finishCurrent()
                current = GraphTurnPoint(
                    id: event.id,
                    turnId: event.turnId,
                    prompt: event.text ?? "(prompt 내용 없음)",
                    response: "",
                    startedAt: event.timestamp,
                    completed: false,
                    failed: false,
                    progress: 0
                )
                continue
            }
            guard var turn = current else { continue }
            switch event.type {
            case "agent_message_chunk":
                turn = copy(turn, response: turn.response + (event.text ?? ""))
            case "tool_call", "permission_request", "elicitation_request":
                // Gateway의 최종 result와 동일하게 마지막 경계 이후의 메시지만 남긴다.
                turn = copy(turn, response: "")
            case "turn_end":
                turn = copy(turn, completed: true)
                current = turn
                finishCurrent()
                continue
            case "error":
                turn = copy(turn, response: event.text ?? turn.response, completed: true, failed: true)
                current = turn
                finishCurrent()
                continue
            default:
                break
            }
            current = turn
        }
        finishCurrent()
        return turns
    }

    private static func copy(
        _ turn: GraphTurnPoint,
        response: String? = nil,
        completed: Bool? = nil,
        failed: Bool? = nil
    ) -> GraphTurnPoint {
        GraphTurnPoint(
            id: turn.id,
            turnId: turn.turnId,
            prompt: turn.prompt,
            response: response ?? turn.response,
            startedAt: turn.startedAt,
            completed: completed ?? turn.completed,
            failed: failed ?? turn.failed,
            progress: turn.progress
        )
    }

    private static func turnOrder(_ lhs: GraphTurnPoint, _ rhs: GraphTurnPoint) -> Bool {
        if lhs.startedAt != rhs.startedAt { return (lhs.startedAt ?? "") < (rhs.startedAt ?? "") }
        return lhs.id < rhs.id
    }
}
