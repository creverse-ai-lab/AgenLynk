import Foundation

enum Phase6CheckError: Error { case failed(String) }

actor FakeProcessState {
    enum TerminationBehavior { case exit, ignore }

    private(set) var running: Bool
    private let terminationBehavior: TerminationBehavior
    private(set) var terminateCount = 0
    private(set) var forceCount = 0

    init(running: Bool, terminationBehavior: TerminationBehavior) {
        self.running = running
        self.terminationBehavior = terminationBehavior
    }

    func isRunning() -> Bool { running }
    func terminate() {
        terminateCount += 1
        if terminationBehavior == .exit { running = false }
    }
    func forceTerminate() {
        forceCount += 1
        running = false
    }
    func counts() -> (Int, Int) { (terminateCount, forceCount) }
}

@main
enum Phase6ArchitectureChecks {
    static func main() async throws {
        try await boundedTerminationHandlesEarlyExitGracefulExitAndHang()
        try reducerReusesPhase1AndPhase5Fixtures()
        try reducerOrdersAndDeduplicatesReplayEvents()
        try reducerArchivesRemovedSessionsFromPriorLiveState()
        try reducerCapsOrdersAndDeduplicatesArchivedHistoryEvents()
        print("Swift Phase 6 architecture checks passed")
    }

    private static func boundedTerminationHandlesEarlyExitGracefulExitAndHang() async throws {
        let early = FakeProcessState(running: false, terminationBehavior: .exit)
        let earlyResult = await stop(early)
        try check(earlyResult == SidecarProcessStopResult(forceTerminationUsed: false, stopped: true), "early exit should be a no-op")
        let earlyCounts = await early.counts()
        try check(earlyCounts == (0, 0), "early exit must not signal a dead process")

        let graceful = FakeProcessState(running: true, terminationBehavior: .exit)
        let gracefulResult = await stop(graceful)
        try check(gracefulResult == SidecarProcessStopResult(forceTerminationUsed: false, stopped: true), "SIGTERM exit should not force kill")
        let gracefulCounts = await graceful.counts()
        try check(gracefulCounts == (1, 0), "graceful exit should receive exactly one SIGTERM")

        let hanging = FakeProcessState(running: true, terminationBehavior: .ignore)
        let started = DispatchTime.now().uptimeNanoseconds
        let hangingResult = await stop(hanging)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        try check(hangingResult == SidecarProcessStopResult(forceTerminationUsed: true, stopped: true), "SIGTERM-ignoring process should be force killed")
        let hangingCounts = await hanging.counts()
        try check(hangingCounts == (1, 1), "hung process should receive one graceful and one force signal")
        try check(elapsed < 500_000_000, "bounded shutdown must not block the UI thread indefinitely")
    }

    private static func stop(_ fake: FakeProcessState) async -> SidecarProcessStopResult {
        await BoundedProcessTermination.stop(
            timeoutNanoseconds: 50_000_000,
            pollNanoseconds: 5_000_000,
            isRunning: { await fake.isRunning() },
            terminate: { await fake.terminate() },
            forceTerminate: { await fake.forceTerminate() }
        )
    }

    private static func reducerReusesPhase1AndPhase5Fixtures() throws {
        let root = repositoryRoot()
        let snapshot = try MonitorSnapshot.decode(Data(contentsOf: root.appendingPathComponent("sidecar/test/fixtures/monitor-snapshot-v1.json")))
        var state = MonitorReducerState()
        _ = MonitorReducer.apply(snapshot: snapshot, to: &state)
        try check(state.sessions.first?.sessionId == "s1", "Phase 1 snapshot session must reduce")
        try check(state.logEventsBySession["old"]?.first?.type == "turn_end", "Phase 1 history must project into logs")

        for name in ["event-flood.ndjson", "subscription-gap.ndjson"] {
            let trace = try String(
                contentsOf: root.appendingPathComponent("sidecar/test/fixtures/monitor-traces/\(name)"),
                encoding: .utf8
            )
            guard let last = trace.split(whereSeparator: \Character.isNewline).last,
                  let raw = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
                  var expected = raw["snapshot"] as? [String: Any] else {
                throw Phase6CheckError.failed("malformed Phase 5 trace \(name)")
            }
            expected["schemaVersion"] = expected["schemaVersion"] ?? 1
            expected["monitorApiVersion"] = expected["monitorApiVersion"] ?? "1.0"
            let decoded = try MonitorSnapshot.decode(try JSONSerialization.data(withJSONObject: expected))
            var reduced = MonitorReducerState()
            _ = MonitorReducer.apply(snapshot: decoded, to: &reduced)
            try check(reduced.eventsBySession == decoded.eventsBySession, "Phase 5 trace must reduce deterministically: \(name)")
        }
    }

    private static func reducerOrdersAndDeduplicatesReplayEvents() throws {
        func event(_ sequence: Int) throws -> MonitorEvent {
            guard let value = MonitorEvent(.object([
                "sessionId": .string("s"), "sequence": .number(Double(sequence)),
                "type": .string("agent_message_chunk")
            ])) else { throw Phase6CheckError.failed("event fixture did not decode") }
            return value
        }
        var state = MonitorReducerState()
        let changed = try MonitorReducer.append(events: [event(3), event(1), event(2), event(2)], to: &state)
        try check(changed, "reducer should accept new events")
        try check(state.eventsBySession["s"]?.compactMap(\.sequence) == [1, 2, 3], "reducer must sort and deduplicate replay")
        try check(state.logEventsBySession["s"]?.compactMap(\.sequence) == [1, 2, 3], "log projection must match canonical events")
    }

    private static func reducerArchivesRemovedSessionsFromPriorLiveState() throws {
        func session(_ id: String, status: String) throws -> GatewaySession {
            guard let value = GatewaySession(.object([
                "sessionId": .string(id), "provider": .string("codex"), "status": .string(status)
            ])) else { throw Phase6CheckError.failed("session fixture did not decode") }
            return value
        }
        func event(_ sessionId: String, _ sequence: Int) throws -> MonitorEvent {
            guard let value = MonitorEvent(.object([
                "sessionId": .string(sessionId), "sequence": .number(Double(sequence)),
                "type": .string("agent_message_chunk")
            ])) else { throw Phase6CheckError.failed("event fixture did not decode") }
            return value
        }

        let live = try session("s1", status: "running")
        let staleHistory = try session("s1", status: "idle")
        let kept = try session("s2", status: "running")
        var state = MonitorReducerState()
        state.sessions = [live, kept]
        state.eventsBySession = [
            "s1": [try event("s1", 1), try event("s1", 2)],
            "s2": [try event("s2", 1)],
            "ghost": [try event("ghost", 9)]
        ]
        state.historySessions = [staleHistory]
        state.historyEventsBySession = ["s1": [try event("s1", 1)]]

        let effect = MonitorReducer.applyStateMessage([
            "sessions": .array([
                .object([
                    "sessionId": .string("s2"), "provider": .string("codex"), "status": .string("running")
                ])
            ]),
            "removedSessionIds": .array([.string("s1"), .string("ghost"), .string("unknown")])
        ], to: &state)

        try check(effect.logChanged, "archiving a known removed session must mark the log dirty")
        try check(state.sessions.map(\.sessionId) == ["s2"], "live sessions must be replaced after archival")
        try check(state.eventsBySession.keys.sorted() == ["s2"], "removed live buckets must be filtered after archival")
        try check(state.historySessions == [live], "prior live session must be upserted exactly into history")
        try check(
            state.historyEventsBySession["s1"]?.compactMap(\.sequence) == [1, 2],
            "history events must merge the prior live bucket and dedup by id"
        )
        try check(
            !state.historySessions.contains { $0.sessionId == "ghost" || $0.sessionId == "unknown" },
            "unknown removed ids must not be archived"
        )
        try check(state.historyEventsBySession["ghost"] == nil, "unknown removed ids must not create history event buckets")
        try check(state.historyEventsBySession["unknown"] == nil, "unknown removed ids must not create history event buckets")
        try check(state.logSessions.map(\.sessionId).sorted() == ["s1", "s2"], "rebuildLog must project archived and live sessions")
    }

    private static func reducerCapsOrdersAndDeduplicatesArchivedHistoryEvents() throws {
        func session(_ id: String) throws -> GatewaySession {
            guard let value = GatewaySession(.object([
                "sessionId": .string(id), "provider": .string("codex"), "status": .string("running")
            ])) else { throw Phase6CheckError.failed("session fixture did not decode") }
            return value
        }
        func event(_ sequence: Int) throws -> MonitorEvent {
            guard let value = MonitorEvent(.object([
                "sessionId": .string("s"), "sequence": .number(Double(sequence)),
                "type": .string("agent_message_chunk")
            ])) else { throw Phase6CheckError.failed("event fixture did not decode") }
            return value
        }

        var history: [MonitorEvent] = []
        for sequence in stride(from: 1500, through: 1, by: -1) {
            history.append(try event(sequence))
        }
        var liveEvents: [MonitorEvent] = []
        for sequence in stride(from: 2500, through: 1000, by: -1) {
            liveEvents.append(try event(sequence))
        }
        liveEvents.append(try event(2000))

        var state = MonitorReducerState()
        state.sessions = [try session("s")]
        state.historyEventsBySession = ["s": history]
        state.eventsBySession = ["s": liveEvents]

        _ = MonitorReducer.applyStateMessage([
            "sessions": .array([]),
            "removedSessionIds": .array([.string("s")])
        ], to: &state)

        let archived = state.historyEventsBySession["s"] ?? []
        try check(archived.count == 2_000, "archived history must cap at 2000")
        try check(Set(archived.map(\.id)).count == archived.count, "archived history must dedup by event id")
        try check(
            archived.compactMap(\.sequence) == Array(501...2500),
            "archived history must keep the newest 2000 after withinSessionEventOrder"
        )
        try check(
            zip(archived, archived.dropFirst()).allSatisfy { !withinSessionEventOrder($1, $0) },
            "archived history must be sorted with withinSessionEventOrder"
        )
        try check(state.sessions.isEmpty, "removed session must leave the live list")
        try check(state.eventsBySession["s"] == nil, "removed session must leave the live event bucket")
    }

    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Phase6CheckError.failed(message) }
    }
}
