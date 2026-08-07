import Foundation

@main
enum MonitorModelChecks {
    static func main() throws {
        try snapshotDecodesSessionsEventsTasksAndInbox()
        try sessionConfigDecodesSelectAndBooleanOptions()
        try gatewayConfigDecodesAllControlMetadata()
        try petSnapshotMapsGatewayStateAndPendingInbox()
        try petSnapshotSeparatesFrontdoorInstancesAndParsesLegacyTimestamps()
        try graphProjectionGroupsFrontdoorsAndAssignsWorkerLanes()
        try graphProjectionBuildsPromptReturnTurnsAndUsesCanvasHeight()
        print("Swift model checks passed")
    }

    private static func petSnapshotMapsGatewayStateAndPendingInbox() throws {
        let sessionValue = JSONValue.object([
            "sessionId": .string("gateway-1"), "acpSessionId": .string("worker-1"),
            "provider": .string("claude"), "model": .string("sonnet"),
            "status": .string("idle"), "cwd": .string("/tmp/project"),
            "opener": .string("codex"),
            "openerInstanceId": .string("codex-main-1"),
            "title": .string("review"), "updatedAt": .string("2026-08-07T00:00:00.000Z")
        ])
        let inboxValue = JSONValue.object([
            "inboxId": .string("inbox-1"), "sessionId": .string("gateway-1"),
            "status": .string("pending"), "type": .string("permission_request")
        ])
        guard let session = GatewaySession(sessionValue) else {
            throw CheckError.failed("pet fixture creation failed")
        }
        let inbox = MonitorRecord(inboxValue, fallbackKind: "inbox", index: 0)
        let snapshot = PetSnapshot.make(sessions: [session], inbox: [inbox], now: Date(timeIntervalSince1970: 0))
        try check(snapshot.sessions.count == 2, "pet snapshot should include frontdoor and Gateway worker")
        let frontdoor = snapshot.sessions.first { $0.role == "frontdoor" }
        let worker = snapshot.sessions.first { $0.role == "worker" }
        try check(frontdoor?.provider == "codex", "session opener should identify the frontdoor")
        try check(frontdoor?.state == "running", "a pending delegated request should keep the frontdoor active")
        try check(frontdoor?.delegated == false, "frontdoor should not be marked delegated")
        try check(worker?.session == "gateway-1", "pet should use the globally unique Gateway session id")
        try check(worker?.parent == frontdoor?.session, "worker should attach to its frontdoor root")
        try check(worker?.state == "needs_input", "pending inbox should override idle state")
        try check(worker?.inboxPending == 1, "pending inbox count should be shared")
        try check(worker?.delegated == true, "Gateway workers should be marked delegated")
    }

    private static func petSnapshotSeparatesFrontdoorInstancesAndParsesLegacyTimestamps() throws {
        func session(id: String, instanceId: String?, cwd: String = "/tmp/project") throws -> GatewaySession {
            var value: [String: JSONValue] = [
                "sessionId": .string(id), "provider": .string("claude"),
                "status": .string("idle"), "cwd": .string(cwd),
                "opener": .string("codex"), "updatedAt": .string("2026-08-07T00:00:00Z")
            ]
            if let instanceId { value["openerInstanceId"] = .string(instanceId) }
            guard let decoded = GatewaySession(.object(value)) else {
                throw CheckError.failed("frontdoor fixture creation failed")
            }
            return decoded
        }

        let snapshot = PetSnapshot.make(
            sessions: [
                try session(id: "one", instanceId: "main-1"),
                try session(id: "two", instanceId: "main-2"),
                try session(id: "three", instanceId: "main-1", cwd: "/tmp/other")
            ],
            inbox: [],
            now: Date(timeIntervalSince1970: 1)
        )
        let frontdoors = snapshot.sessions.filter { $0.role == "frontdoor" }
        try check(frontdoors.count == 2, "concurrent frontdoor bridge instances must not be merged")
        try check(Set(frontdoors.map(\.session)).count == 2, "synthetic frontdoor ids must be unique")
        try check(snapshot.sessions.filter { $0.role == "worker" }.count == 3, "one frontdoor instance may own workers in multiple directories")
        let workerTimes = snapshot.sessions.filter { $0.role == "worker" }.map(\.time)
        try check(workerTimes.allSatisfy { $0 > 1 }, "non-fractional ISO8601 timestamps must not fall back to now")

        let legacy = PetSnapshot.make(
            sessions: [try session(id: "legacy", instanceId: nil)], inbox: [], now: Date(timeIntervalSince1970: 1)
        )
        try check(legacy.sessions.first { $0.role == "frontdoor" }?.provider == "codex", "legacy sessions should use opener/cwd fallback")
    }

    private static func snapshotDecodesSessionsEventsTasksAndInbox() throws {
        let data = Data(#"""
        {
          "connected":true,
          "gateway":{"gatewayVersion":"1.3.1"},
          "sessions":[{"sessionId":"s1","provider":"codex","status":"running","cwd":"/tmp/project","eventCount":2}],
          "events":{"s1":[{"sessionId":"s1","sequence":0,"type":"turn_start","ts":"2026-08-07T00:00:00.000Z","text":"work"}]},
          "tasks":[{"taskId":"t1","status":"working","statusMessage":"running"}],
          "inbox":[{"inboxId":"i1","status":"pending","type":"permission_request","sessionId":"s1"}]
        }
        """#.utf8)
        let snapshot = try MonitorSnapshot.decode(data)
        try check(snapshot.connected, "snapshot should be connected")
        try check(snapshot.streaming, "snapshot should default streaming to connected for compatibility")
        try check(snapshot.sessions.first?.sessionId == "s1", "session decode failed")
        try check(snapshot.eventsBySession["s1"]?.first?.type == "turn_start", "event decode failed")
        try check(snapshot.tasks.first?.id == "t1", "task decode failed")
        try check(snapshot.inbox.first?.id == "i1", "inbox decode failed")
    }

    private static func sessionConfigDecodesSelectAndBooleanOptions() throws {
        let data = Data(#"""
        {
          "sessionId":"s1",
          "configOptions":[
            {"type":"select","id":"thought_level","name":"Thought level","category":"thought_level","currentValue":"medium","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"}]},
            {"type":"boolean","id":"auto_compact","name":"Auto compact","currentValue":true}
          ]
        }
        """#.utf8)
        let response = try SessionConfigResponse.decode(data)
        try check(response.sessionId == "s1", "config session decode failed")
        try check(response.options.count == 2, "config options decode failed")
        try check(response.options[0].choices.last?.value == "medium", "select choices decode failed")
        try check(response.options[1].currentValue.boolValue == true, "boolean config decode failed")
    }

    private static func gatewayConfigDecodesAllControlMetadata() throws {
        let data = Data(#"""
        {
          "ok":true,
          "pendingRestart":true,
          "pendingLiveApply":false,
          "options":[
            {"id":"maxEvents","group":"resourceLimits","type":"number","label":"Events per session","description":"limit","unit":"count","minimum":1,"defaultValue":200,"currentValue":200,"configuredValue":400,"storedValue":400,"source":"stored","environment":"ACP_GATEWAY_MAX_EVENTS","editable":true,"requiresRestart":true,"pending":true},
            {"id":"agentAutoUpdate","group":"agentUpdates","type":"boolean","label":"Automatic adapter updates","description":"updates","defaultValue":true,"currentValue":false,"configuredValue":false,"storedValue":false,"source":"stored","environment":"ACP_GATEWAY_AGENT_AUTO_UPDATE","editable":true,"requiresRestart":false,"pending":false}
          ]
        }
        """#.utf8)
        let snapshot = try GatewayConfigSnapshot.decode(data)
        try check(snapshot.pendingRestart, "gateway pending restart decode failed")
        try check(snapshot.options.count == 2, "gateway config options decode failed")
        try check(snapshot.options[0].configuredValue.intValue == 400, "gateway number config decode failed")
        try check(snapshot.options[1].configuredValue.boolValue == false, "gateway boolean config decode failed")
        try check(snapshot.options[0].environment == "ACP_GATEWAY_MAX_EVENTS", "gateway environment metadata decode failed")
    }

    private static func graphProjectionGroupsFrontdoorsAndAssignsWorkerLanes() throws {
        let sessionValue = JSONValue.object([
            "sessionId": .string("s1"), "provider": .string("codex"), "status": .string("running"),
            "cwd": .string("/tmp/project"), "opener": .string("grok"), "createdAt": .string("2026-08-07T00:00:00.000Z")
        ])
        let eventValue = JSONValue.object([
            "sessionId": .string("s1"), "sequence": .number(0), "type": .string("turn_start"),
            "ts": .string("2026-08-07T00:05:00.000Z")
        ])
        guard let session = GatewaySession(sessionValue), let event = MonitorEvent(eventValue),
              let now = parseTimestamp("2026-08-07T00:10:00.000Z") else {
            throw CheckError.failed("fixture creation failed")
        }
        let projection = GraphProjection.make(
            sessions: [session], eventsBySession: ["s1": [event]], windowMinutes: 15, now: now
        )
        try check(projection.groups.count == 1, "frontdoor grouping failed")
        try check(projection.groups.first?.opener == "grok", "frontdoor opener failed")
        try check(projection.lanes.first?.turns.count == 1, "turn projection failed")
        try check((projection.lanes.first?.laneX ?? 0) > (projection.groups.first?.trunkX ?? 0), "lane placement failed")
    }

    private static func graphProjectionBuildsPromptReturnTurnsAndUsesCanvasHeight() throws {
        let sessionValue = JSONValue.object([
            "sessionId": .string("s1"), "provider": .string("codex"), "status": .string("idle"),
            "cwd": .string("/tmp/project"), "opener": .string("codex")
        ])
        let fixtures: [[String: JSONValue]] = [
            ["sequence": .number(0), "type": .string("turn_start"), "ts": .string("2026-08-07T00:09:00.000Z"), "turnId": .string("t1"), "text": .string("first prompt")],
            ["sequence": .number(1), "type": .string("agent_message_chunk"), "ts": .string("2026-08-07T00:09:01.000Z"), "turnId": .string("t1"), "text": .string("progress")],
            ["sequence": .number(2), "type": .string("tool_call"), "ts": .string("2026-08-07T00:09:02.000Z"), "turnId": .string("t1")],
            ["sequence": .number(3), "type": .string("agent_message_chunk"), "ts": .string("2026-08-07T00:09:03.000Z"), "turnId": .string("t1"), "text": .string("final answer")],
            ["sequence": .number(4), "type": .string("turn_end"), "ts": .string("2026-08-07T00:09:04.000Z"), "turnId": .string("t1")],
            ["sequence": .number(5), "type": .string("turn_start"), "ts": .string("2026-08-07T00:09:30.000Z"), "turnId": .string("t2"), "text": .string("second prompt")],
            ["sequence": .number(6), "type": .string("agent_message_chunk"), "ts": .string("2026-08-07T00:09:31.000Z"), "turnId": .string("t2"), "text": .string("second return")],
            ["sequence": .number(7), "type": .string("turn_end"), "ts": .string("2026-08-07T00:09:32.000Z"), "turnId": .string("t2")]
        ]
        guard let session = GatewaySession(sessionValue),
              let now = parseTimestamp("2026-08-07T00:10:00.000Z") else {
            throw CheckError.failed("turn fixture creation failed")
        }
        let events = fixtures.compactMap { fixture -> MonitorEvent? in
            var value = fixture
            value["sessionId"] = .string("s1")
            return MonitorEvent(.object(value))
        }
        let projection = GraphProjection.make(
            sessions: [session], eventsBySession: ["s1": events], windowMinutes: 15, now: now
        )
        let turns = projection.lanes.first?.turns ?? []
        try check(turns.count == 2, "events should collapse into two human-readable turns")
        try check(turns[0].prompt == "first prompt", "prompt should come from turn_start")
        try check(turns[0].response == "final answer", "return should keep the final segment after a tool boundary")
        try check(turns[0].progress == 0.1 && turns[1].progress == 0.9, "short live bursts should use the canvas height")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError.failed(message) }
    }
}

enum CheckError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}
