import ACPShared
import Foundation

private enum CheckError: Error { case failed(String) }

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError.failed(message) }
}

@main
struct MenuBarPipelineTests {
    static func main() throws {
        try pipelineFollowsParentLinksAndOrdersByUrgency()
        try waitReasonAndCurrentStepComeFromEvents()
        try manyQuietStepsFoldButWaitingOnesStay()
        print("Swift menu bar pipeline checks passed")
    }

    private static func session(
        _ id: String, status: String, opener: String = "main", role: String = "worker",
        parent: String? = nil, created: String = "2026-09-26T00:00:00.000Z", updated: String? = nil,
        turnId: String? = nil
    ) throws -> GatewaySession {
        var object: [String: JSONValue] = [
            "sessionId": .string(id), "provider": .string("codex"), "status": .string(status),
            "openerInstanceId": .string(opener), "role": .string(role), "createdAt": .string(created),
            "updatedAt": .string(updated ?? created)
        ]
        if let parent { object["parentSessionId"] = .string(parent) }
        if let turnId { object["turnId"] = .string(turnId) }
        guard let value = GatewaySession(.object(object)) else { throw CheckError.failed("session \(id) did not decode") }
        return value
    }

    private static func event(_ id: String, session: String, kind: String, turn: String, title: String? = nil, status: String? = nil, ts: String) throws -> MonitorEvent {
        var object: [String: JSONValue] = [
            "id": .string("\(session)#\(id)"), "key": .string(id), "sessionId": .string(session), "kind": .string(kind),
            "ts": .string(ts), "turnId": .string(turn), "sources": .array([.string("transcript")])
        ]
        if let title { object["title"] = .string(title) }
        if let status { object["status"] = .string(status) }
        guard let value = MonitorEvent(.object(object)) else { throw CheckError.failed("event \(id) did not decode") }
        return value
    }

    private static func pipelineFollowsParentLinksAndOrdersByUrgency() throws {
        let busy = FrontdoorSession.make(sessions: [
            try session("root", status: "running", role: "frontdoor"),
            try session("w1", status: "running", parent: "root", created: "2026-09-26T00:01:00.000Z"),
            try session("w2", status: "waiting_permission", parent: "w1", created: "2026-09-26T00:02:00.000Z"),
            try session("w3", status: "idle", created: "2026-09-26T00:03:00.000Z")
        ])
        let quiet = FrontdoorSession.make(sessions: [try session("other", status: "idle", opener: "main-2", role: "frontdoor")])
        let running = FrontdoorSession.make(sessions: [try session("r", status: "running", opener: "main-3", role: "frontdoor")])
        let pipeline = MenuBarPipeline.make(frontdoors: running + quiet + busy, eventsBySession: [:])

        try check(pipeline.activeCards.map(\.id) == ["main", "main-3"], "a card waiting for the user comes before a running one")
        try check(pipeline.idleCards.map(\.id) == ["main-2"], "idle work folds away")
        let card = pipeline.activeCards[0]
        try check(card.stages.map(\.id) == ["root", "w1", "w2", "w3"], "stages follow the delegation chain, parent before child")
        try check(card.stages.map(\.depth) == [0, 1, 2, 1], "a worker without a parent link hangs off the Frontdoor")
        try check(card.urgency == .permission && card.focus?.id == "w2", "the card calls out the step that needs the user")
        try check(pipeline.permissionCount == 1 && pipeline.runningCount == 3, "summary counts steps across cards")
    }

    private static func waitReasonAndCurrentStepComeFromEvents() throws {
        let sessions = [
            try session("root", status: "waiting_permission", role: "frontdoor", turnId: "t"),
        ]
        let events = [
            try event("start", session: "root", kind: "turn_start", turn: "t", title: "fix the build", ts: "2026-09-26T00:00:00.000Z"),
            try event("tool:1", session: "root", kind: "tool_call", turn: "t", title: "Bash: npm test", status: "completed", ts: "2026-09-26T00:00:01.000Z"),
            try event("perm:1", session: "root", kind: "permission_request", turn: "t", title: "Bash: rm -rf build", status: "pending", ts: "2026-09-26T00:00:02.000Z")
        ]
        let pipeline = MenuBarPipeline.make(frontdoors: FrontdoorSession.make(sessions: sessions), eventsBySession: ["root": events])
        let stage = pipeline.activeCards[0].stages[0]
        try check(stage.waitReason?.hasPrefix("Bash: rm -rf") == true, "a permission wait names the tool it waits on")
        try check(stage.currentStep != nil, "a busy step says what it is doing")
        try check(stage.turnStartedAt != nil, "elapsed time starts at the turn's start")
    }

    private static func manyQuietStepsFoldButWaitingOnesStay() throws {
        var sessions = [try session("root", status: "running", role: "frontdoor")]
        for index in 1...7 {
            sessions.append(try session("w\(index)", status: "idle", parent: "root", created: "2026-09-26T00:0\(index):00.000Z"))
        }
        sessions.append(try session("late", status: "waiting_input", parent: "root", created: "2026-09-26T00:09:00.000Z"))
        let card = MenuBarPipeline.make(frontdoors: FrontdoorSession.make(sessions: sessions), eventsBySession: [:], maxStages: 4).activeCards[0]
        try check(card.stages.count == 5 && card.stages.last?.id == "late", "a waiting step is never folded away")
        try check(card.hiddenStageCount == 4, "quiet steps past the limit fold into +N")
    }
}
