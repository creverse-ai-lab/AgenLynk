import ACPShared
import Foundation

/// The menu bar's view of work in progress: one card per Frontdoor, its
/// sessions laid out as the delegation pipeline (Frontdoor → Worker → nested
/// Worker), the most urgent step called out. Pure, so it is tested without
/// SwiftUI and recomputed only when the sessions or events change.
struct MenuBarPipeline: Equatable, Sendable {
    /// What a step needs from the user, most urgent first.
    enum Urgency: Int, Comparable, Sendable {
        case permission, input, error, running, idle, closed

        static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }

        init(status: String) {
            switch status {
            case "waiting_permission": self = .permission
            case "waiting_input": self = .input
            case "error", "failed": self = .error
            case "running", "cancelling", "restoring", "starting": self = .running
            case "closed", "disconnected", "unavailable": self = .closed
            default: self = .idle
            }
        }

        var needsUser: Bool { self == .permission || self == .input }
    }

    struct Stage: Identifiable, Equatable, Sendable {
        let session: GatewaySession
        /// 0 = the Frontdoor (or a top-level worker without one).
        let depth: Int
        let urgency: Urgency
        /// What it waits for: the pending permission's tool, or the question.
        let waitReason: String?
        /// The latest step of its running turn ("도구 3개 · 실행 중: Bash: …").
        let currentStep: String?
        let turnStartedAt: Date?
        let forecast: UsageForecast

        var id: String { session.sessionId }
    }

    struct Card: Identifiable, Equatable, Sendable {
        let frontdoor: FrontdoorSession
        /// Pipeline order: parent before child, siblings by creation.
        let stages: [Stage]
        /// Stages beyond the card's limit (still counted in `urgency`).
        let hiddenStageCount: Int
        let urgency: Urgency
        /// The step the card calls out: the most urgent, newest on ties.
        let focus: Stage?
        let work: WorkUsage

        var id: String { frontdoor.id }
    }

    /// Needs the user, running, or failed — shown as cards.
    let activeCards: [Card]
    /// Nothing happening — folded into one line.
    let idleCards: [Card]

    var runningCount: Int { stageCount(.running) }
    var permissionCount: Int { stageCount(.permission) }
    var inputCount: Int { stageCount(.input) }

    private func stageCount(_ urgency: Urgency) -> Int {
        (activeCards + idleCards).reduce(0) { total, card in
            total + card.stages.filter { $0.urgency == urgency }.count
        }
    }

    static func make(
        frontdoors: [FrontdoorSession],
        eventsBySession: [String: [MonitorEvent]],
        maxStages: Int = 5
    ) -> MenuBarPipeline {
        let cards = frontdoors
            .map { card(for: $0, eventsBySession: eventsBySession, maxStages: maxStages) }
            .sorted(by: cardOrder)
        return MenuBarPipeline(
            activeCards: cards.filter { $0.urgency <= .running },
            idleCards: cards.filter { $0.urgency > .running }
        )
    }

    /// Needs-the-user first (the longest waiting on top), then errors, then
    /// running (newest activity on top), then idle and closed.
    private static func cardOrder(_ lhs: Card, _ rhs: Card) -> Bool {
        if lhs.urgency != rhs.urgency { return lhs.urgency < rhs.urgency }
        let left = lhs.frontdoor.updatedAt ?? ""
        let right = rhs.frontdoor.updatedAt ?? ""
        return lhs.urgency.needsUser ? left < right : left > right
    }

    private static func card(for frontdoor: FrontdoorSession, eventsBySession: [String: [MonitorEvent]], maxStages: Int) -> Card {
        let ordered = pipelineOrder(frontdoor)
        let stages = ordered.map { member in
            stage(member.session, depth: member.depth, events: eventsBySession[member.session.sessionId] ?? [])
        }
        let urgency = stages.map(\.urgency).min() ?? .idle
        let focus = stages
            .filter { $0.urgency == urgency }
            .max { ($0.session.updatedAt ?? "") < ($1.session.updatedAt ?? "") }
        // Keep the head of the pipeline and every step that needs attention;
        // quiet steps past the limit fold into "+N".
        var shown: [Stage] = []
        for stage in stages where shown.count < maxStages || stage.urgency <= .running {
            shown.append(stage)
        }
        return Card(
            frontdoor: frontdoor,
            stages: shown,
            hiddenStageCount: stages.count - shown.count,
            urgency: urgency,
            focus: focus,
            work: WorkUsage(sessions: frontdoor.members)
        )
    }

    /// Depth-first from the Frontdoor, following `parentSessionId`; a worker
    /// whose parent is not in the group hangs off the Frontdoor.
    static func pipelineOrder(_ frontdoor: FrontdoorSession) -> [(session: GatewaySession, depth: Int)] {
        let members = frontdoor.members
        let ids = Set(members.map(\.sessionId))
        let rootId = frontdoor.root?.sessionId
        var children: [String: [GatewaySession]] = [:]
        var tops: [GatewaySession] = []
        for session in frontdoor.workers {
            if let parent = session.parentSessionId, ids.contains(parent), parent != session.sessionId {
                children[parent, default: []].append(session)
            } else if let rootId {
                children[rootId, default: []].append(session)
            } else {
                tops.append(session)
            }
        }
        var result: [(GatewaySession, Int)] = []
        var visited = Set<String>()
        func visit(_ session: GatewaySession, depth: Int) {
            guard visited.insert(session.sessionId).inserted else { return }
            result.append((session, depth))
            for child in (children[session.sessionId] ?? []).sorted(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }) {
                visit(child, depth: depth + 1)
            }
        }
        if let root = frontdoor.root { visit(root, depth: 0) }
        for top in tops.sorted(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }) { visit(top, depth: 0) }
        // A cycle or a dangling link must not drop a session from the card.
        for session in members where !visited.contains(session.sessionId) { visit(session, depth: 1) }
        return result.map { (session: $0.0, depth: $0.1) }
    }

    private static func stage(_ session: GatewaySession, depth: Int, events: [MonitorEvent]) -> Stage {
        let urgency = Urgency(status: session.status)
        let forecast = UsageForecast(session: session)
        let turnEvents = session.turnId.map { turn in events.filter { $0.turnId == turn } } ?? []
        let turnStart = forecast.currentTurnStartedAt.flatMap(parseTimestamp)
            ?? turnEvents.first(where: { $0.kind == "turn_start" })?.timestamp.flatMap(parseTimestamp)
        return Stage(
            session: session,
            depth: depth,
            urgency: urgency,
            waitReason: waitReason(urgency, events: events),
            currentStep: urgency <= .running ? currentStep(turnEvents.isEmpty ? Array(events.suffix(40)) : turnEvents) : nil,
            turnStartedAt: urgency <= .running ? turnStart : nil,
            forecast: forecast
        )
    }

    private static func waitReason(_ urgency: Urgency, events: [MonitorEvent]) -> String? {
        switch urgency {
        case .permission:
            guard let request = events.last(where: { $0.kind == "permission_request" && $0.isInFlight }) else {
                return "권한 승인이 필요합니다"
            }
            return request.compactToolTitle(limit: 40)
        case .input:
            guard let request = events.last(where: { $0.kind == "input_request" && $0.isInFlight }) else {
                return "사용자 입력이 필요합니다"
            }
            return (request.body ?? request.title).map { oneLine($0, limit: 44) } ?? "사용자 입력이 필요합니다"
        default:
            return nil
        }
    }

    /// The newest thing the turn is doing, a run of tool calls summarized.
    private static func currentStep(_ events: [MonitorEvent]) -> String? {
        guard let last = EventTimeline.group(events).last else { return nil }
        switch last {
        case let .tools(group):
            return group.summary(titleLimit: 24)
        case let .event(event):
            if event.kind == "tool_call" { return "도구 호출: \(event.compactToolTitle(limit: 30))" }
            if event.kind == "turn_start" { return "시작: \(oneLine(event.title ?? event.body ?? "새 턴", limit: 36))" }
            return event.kindLabel
        }
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
