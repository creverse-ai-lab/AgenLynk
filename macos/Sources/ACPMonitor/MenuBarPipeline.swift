import ACPShared
import Foundation

/// The menu bar's view of work in progress: one card per Frontdoor, its
/// sessions laid out as the delegation pipeline (Frontdoor → Worker → nested
/// Worker), the most urgent step called out. Pure, so it is tested without
/// SwiftUI and recomputed only when the sessions or events change.
struct MenuBarPipeline: Equatable, Sendable {
    /// What a step needs from the user, most urgent first.
    enum Urgency: Int, Comparable, Sendable {
        /// `awaiting`: a Frontdoor sleeping until its Workers need it.
        case permission, input, error, awaiting, running, idle, closed

        static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }

        init(status: String) {
            switch status {
            case "waiting_permission": self = .permission
            case "waiting_input": self = .input
            // A cancelled turn and an unavailable agent are failures, as the
            // alerts (FrontdoorPhase) and the Pet read them.
            case "error", "failed", "cancelled", "unavailable": self = .error
            case "waiting_tasks": self = .awaiting
            case "running", "cancelling", "restoring", "starting": self = .running
            case "closed", "disconnected": self = .closed
            default: self = .idle
            }
        }

        var needsUser: Bool { self == .permission || self == .input }
        /// Running, waiting on the user, or failed: what the views list.
        /// Idle and closed Workers rest in a folded "대기 중" box.
        var isMoving: Bool { self <= .running }
    }

    /// Whether a session is moving (see `Urgency.isMoving`).
    static func isMoving(_ session: GatewaySession) -> Bool { Urgency(status: session.status).isMoving }

    /// The sequence lanes to hide behind "대기 중 Worker N개": resting Workers
    /// that are not a Frontdoor (or any top-level lane), not the selected
    /// session, and not on the way to a lane that stays. Hiding a lane
    /// therefore hides its whole subtree, so no visible lane loses its parent.
    static func restingLaneIds(_ lanes: [SessionTree.Node], selectedSessionId: String?) -> Set<String> {
        var anchors = Set<String>()
        for lane in lanes where lane.depth == 0 || lane.session.isFrontdoorRecord || isMoving(lane.session)
            || lane.session.sessionId == selectedSessionId {
            anchors.insert(lane.session.sessionId)
        }
        return SessionTree.restingIds(lanes.map { (id: $0.session.sessionId, parentId: $0.parentSessionId) }, anchors: anchors)
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
        /// Waiting (idle or closed) Workers left out of `stages`, in pipeline
        /// order. The menu bar only counts them; the dashboard's 현황 view
        /// lists them under a folded "대기 중 Worker N개".
        let restingStages: [Stage]
        let urgency: Urgency
        /// The step the card calls out: the most urgent, newest on ties.
        let focus: Stage?
        let work: WorkUsage

        var id: String { frontdoor.id }
        var hiddenStageCount: Int { restingStages.count }

        /// How long a Frontdoor that finished its turn reads as "완료" before
        /// it reads as resting ("쉬는 중"); the Pet uses the same.
        static let finishedLinger = MascotTiming.finishedLinger

        /// At rest, and its last activity (the turn's end) within
        /// `finishedLinger` of `now`: just finished rather than resting.
        func justFinished(now: Date) -> Bool {
            urgency == .idle && MascotTiming.justFinished(updated: frontdoor.updatedAt.flatMap(parseTimestamp), now: now)
        }
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
        eventsBySession: [String: [MonitorEvent]]
    ) -> MenuBarPipeline {
        let cards = frontdoors
            .map { card(for: $0, eventsBySession: eventsBySession) }
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

    private static func card(for frontdoor: FrontdoorSession, eventsBySession: [String: [MonitorEvent]]) -> Card {
        let ordered = pipelineOrder(frontdoor)
        let stages = ordered.map { member in
            stage(member.session, depth: member.depth, events: eventsBySession[member.session.sessionId] ?? [])
        }
        let urgency = stages.map(\.urgency).min() ?? .idle
        let focus = stages
            .filter { $0.urgency == urgency }
            .max { ($0.session.updatedAt ?? "") < ($1.session.updatedAt ?? "") }
        // The Frontdoor and every Worker that is doing something or needs the
        // user, plus the parents that connect them; Workers that are only
        // waiting (idle, closed) fold into a count, so a card shows what is
        // moving, not every session it ever opened.
        var anchors = Set(stages.filter { $0.urgency.isMoving }.map(\.id))
        if let rootId = frontdoor.root?.sessionId ?? stages.first(where: { $0.depth == 0 })?.id { anchors.insert(rootId) }
        let resting = SessionTree.restingIds(
            ordered.map { (id: $0.session.sessionId, parentId: $0.parentSessionId) },
            anchors: anchors
        )
        return Card(
            frontdoor: frontdoor,
            stages: stages.filter { !resting.contains($0.id) },
            restingStages: stages.filter { resting.contains($0.id) },
            urgency: urgency,
            focus: focus,
            work: WorkUsage(sessions: frontdoor.members)
        )
    }

    /// Depth-first from the Frontdoor, following `parentSessionId`; a worker
    /// whose parent is not in the group hangs off the Frontdoor. The same
    /// `SessionTree` resolution the dashboard sequence lays its lanes out by.
    static func pipelineOrder(_ frontdoor: FrontdoorSession) -> [(session: GatewaySession, depth: Int, parentSessionId: String?)] {
        SessionTree.order(frontdoor.members, firstRootId: frontdoor.root?.sessionId)
            .map { (session: $0.session, depth: $0.depth, parentSessionId: $0.parentSessionId) }
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
            // A Main asleep on its Workers has no step of its own to show.
            currentStep: urgency <= .running && urgency != .awaiting
                ? currentStep(turnEvents.isEmpty ? Array(events.suffix(40)) : turnEvents) : nil,
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
            return (request.body ?? request.title).map { oneLineText($0, limit: 43) } ?? "사용자 입력이 필요합니다"
        default:
            return nil
        }
    }

    /// The newest thing the turn is doing, a run of tool calls summarized.
    private static func currentStep(_ events: [MonitorEvent]) -> String? {
        guard let last = EventTimeline.lastItem(events) else { return nil }
        switch last {
        case let .tools(group):
            return group.summary(titleLimit: 24)
        case let .event(event):
            if event.kind == "tool_call" { return "도구 호출: \(event.compactToolTitle(limit: 30))" }
            if event.kind == "turn_start" { return "시작: \(oneLineText(event.title ?? event.body ?? "새 턴", limit: 35))" }
            return event.kindLabel
        }
    }
}
