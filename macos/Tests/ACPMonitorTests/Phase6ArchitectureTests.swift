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
        try reducerUpsertsEventsFramesById()
        try reducerArchivesRemovedSessionsFromPriorLiveState()
        try reducerCapsOrdersAndDeduplicatesArchivedHistoryEvents()
        try reducerPrependsOlderEventsBeyondTheStreamCap()
        try reducerDropsHistoryButKeepsLiveOnHistoryCleared()
        try reducerCapsPagedEventsAndPrunesUnknownSessions()
        try reducerReportsNoChangeForARepeatedStateFrame()
        try reducerMergesTruncatedSnapshotsWithoutShrinking()
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

    /// A canonical v2 event; the ts defaults to one shared instant so the
    /// monitor sequence alone decides order.
    private static func event(
        _ sessionId: String,
        _ sequence: Int,
        key: String? = nil,
        kind: String = "agent_message",
        ts: String = "2026-08-07T00:00:00.000Z",
        body: String? = nil,
        status: String? = nil
    ) throws -> MonitorEvent {
        let key = key ?? "msg:\(sequence)"
        var object: [String: JSONValue] = [
            "id": .string("\(sessionId)#\(key)"), "key": .string(key), "sessionId": .string(sessionId),
            "sequence": .number(Double(sequence)), "kind": .string(kind), "ts": .string(ts),
            "sources": .array([.string("gateway")])
        ]
        if let body { object["body"] = .string(body) }
        if let status { object["status"] = .string(status) }
        guard let value = MonitorEvent(.object(object)) else { throw Phase6CheckError.failed("event fixture did not decode") }
        return value
    }

    private static func session(_ id: String, status: String = "running") throws -> GatewaySession {
        guard let value = GatewaySession(.object([
            "sessionId": .string(id), "provider": .string("codex"), "status": .string(status)
        ])) else { throw Phase6CheckError.failed("session fixture did not decode") }
        return value
    }

    private static func frame(_ events: [MonitorEvent]) -> [String: JSONValue] {
        let buckets = Dictionary(grouping: events, by: \.sessionId).mapValues { JSONValue.array($0.map(\.payload)) }
        return ["kind": .string("events"), "events": .object(buckets)]
    }

    private static func reducerReusesPhase1AndPhase5Fixtures() throws {
        let root = repositoryRoot()
        let snapshot = try MonitorSnapshot.decode(Data(contentsOf: root.appendingPathComponent("sidecar/test/fixtures/monitor-snapshot-v2.json")))
        var state = MonitorReducerState()
        _ = MonitorReducer.apply(snapshot: snapshot, to: &state)
        try check(state.sessions.first?.sessionId == "s1", "v2 snapshot session must reduce")
        try check(state.logEventsBySession["old"]?.first?.kind == "turn_end", "v2 history must project into logs")
        try check(state.eventLimit == 2_000, "the snapshot's event limit must reach the reducer")

        for name in ["event-flood.ndjson", "subscription-gap.ndjson"] {
            let trace = try String(
                contentsOf: root.appendingPathComponent("sidecar/test/fixtures/monitor-traces/\(name)"),
                encoding: .utf8
            )
            guard let last = trace.split(whereSeparator: { $0.isNewline }).last,
                  let raw = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
                  var expected = raw["snapshot"] as? [String: Any] else {
                throw Phase6CheckError.failed("malformed Phase 5 trace \(name)")
            }
            expected["schemaVersion"] = expected["schemaVersion"] ?? 2
            expected["monitorApiVersion"] = expected["monitorApiVersion"] ?? "2.0"
            let decoded = try MonitorSnapshot.decode(try JSONSerialization.data(withJSONObject: expected))
            var reduced = MonitorReducerState()
            _ = MonitorReducer.apply(snapshot: decoded, to: &reduced)
            try check(reduced.eventsBySession == decoded.eventsBySession, "Phase 5 trace must reduce deterministically: \(name)")

            // Re-delivering the same events as an `events` frame is a no-op.
            let replayed = decoded.eventsBySession.values.flatMap { $0 }
            try check(!MonitorReducer.applyEventsMessage(frame(replayed), to: &reduced),
                      "upserting identical events must not change state: \(name)")
        }
    }

    private static func reducerUpsertsEventsFramesById() throws {
        var state = MonitorReducerState()
        state.sessions = [try session("s")]
        let changed = MonitorReducer.applyEventsMessage(frame([
            try event("s", 3, ts: "2026-08-07T00:00:03.000Z"),
            try event("s", 1, key: "tool:c1", kind: "tool_call", ts: "2026-08-07T00:00:01.000Z", status: "running"),
            try event("s", 2, ts: "2026-08-07T00:00:02.000Z")
        ]), to: &state)
        try check(changed, "reducer should accept new events")
        try check(state.eventsBySession["s"]?.compactMap(\.sequence) == [1, 2, 3], "events frames must be sorted by ts")
        try check(state.logEventsBySession["s"]?.compactMap(\.sequence) == [1, 2, 3], "log projection must match canonical events")

        // The tool call finishes: same id, new status. It replaces in place.
        MonitorReducer.applyEventsMessage(frame([
            try event("s", 1, key: "tool:c1", kind: "tool_call", ts: "2026-08-07T00:00:01.000Z", body: "done", status: "completed")
        ]), to: &state)
        let bucket = state.eventsBySession["s"] ?? []
        try check(bucket.count == 3, "a same-id event must replace, not append")
        try check(bucket.first?.status == "completed" && bucket.first?.body == "done", "the replacement must win")
        try check(state.logEventsBySession["s"]?.first?.status == "completed", "the log must follow the replacement")

        // A state frame's events are changes too: they never drop the rest.
        let effect = MonitorReducer.applyStateMessage([
            "events": .object(["s": .array([try event("s", 4, ts: "2026-08-07T00:00:04.000Z").payload])])
        ], to: &state)
        try check(effect.logChanged, "state-frame events must mark the log dirty")
        try check(state.eventsBySession["s"]?.compactMap(\.sequence) == [1, 2, 3, 4],
                  "state-frame events must upsert, not replace the bucket")
        _ = MonitorReducer.applyStateMessage(["events": .object(["s": .array([])])], to: &state)
        try check(state.eventsBySession["s"]?.count == 4, "an empty state-frame bucket must not clear events")

        // Events can land before the session list names their session.
        MonitorReducer.applyEventsMessage(frame([try event("early", 1)]), to: &state)
        try check(state.eventsBySession["early"]?.count == 1, "events for a not-yet-listed session are kept live")
    }

    private static func reducerArchivesRemovedSessionsFromPriorLiveState() throws {
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
        try check(state.eventsBySession["s1"] == nil, "an archived session's live bucket must move to history")
        try check(state.eventsBySession["s2"]?.count == 1, "a kept session's events must stay live")
        try check(state.eventsBySession["ghost"]?.count == 1,
                  "events of an unknown session stay where the sidecar keeps them (live, until a snapshot says otherwise)")
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

        // Events for a history-only session land in its history bucket.
        MonitorReducer.applyEventsMessage(frame([try event("s1", 3)]), to: &state)
        try check(state.historyEventsBySession["s1"]?.compactMap(\.sequence) == [1, 2, 3], "history sessions upsert into history")
        try check(state.eventsBySession["s1"] == nil, "a history session must not grow a live bucket")

        // A session reported live again leaves history with its events.
        _ = MonitorReducer.applyStateMessage([
            "sessions": .array([live.payloadForTest, kept.payloadForTest])
        ], to: &state)
        try check(state.historySessions.isEmpty, "a revived session must leave history")
        try check(state.eventsBySession["s1"]?.compactMap(\.sequence) == [1, 2, 3], "a revived session's events move back live")
        try check(state.logEventsBySession["s1"]?.count == 3, "revival must not duplicate log events")

        // session_removed: the Gateway closed it. It stays visible, as closed.
        MonitorReducer.removeSession("s1", from: &state)
        try check(state.historySessions.first { $0.sessionId == "s1" }?.status == "closed", "a closed session is archived as closed")
        try check(state.historyEventsBySession["s1"]?.count == 3, "session_removed must keep the session's events")
        try check(state.logEventsBySession["s1"]?.count == 3, "session_removed must keep the session in the log")

        // The list can drop a Gateway worker before its session_removed
        // arrives; the close still lands, or history shows it running for good.
        state.sessions = [try session("late")]
        _ = MonitorReducer.applyStateMessage(["sessions": .array([])], to: &state)
        try check(state.historySessions.first { $0.sessionId == "late" }?.status == "running",
                  "the list alone archives the last status it showed")
        try check(MonitorReducer.removeSession("late", from: &state), "a late close must change history")
        try check(state.historySessions.first { $0.sessionId == "late" }?.status == "closed",
                  "a late session_removed marks the archived worker closed")
    }

    private static func reducerPrependsOlderEventsBeyondTheStreamCap() throws {
        var state = MonitorReducerState()
        state.eventLimit = 2
        state.sessions = [try session("s")]
        MonitorReducer.applyEventsMessage(frame([
            try event("s", 5, ts: "2026-08-07T00:00:05.000Z"), try event("s", 6, ts: "2026-08-07T00:00:06.000Z")
        ]), to: &state)
        let older = [try event("s", 3, ts: "2026-08-07T00:00:03.000Z"), try event("s", 4, ts: "2026-08-07T00:00:04.000Z")]
        try check(MonitorReducer.prependOlder(older, sessionId: "s", to: &state), "older events must be accepted")
        try check(state.logEventsBySession["s"]?.compactMap(\.sequence) == [3, 4, 5, 6], "older events merge into the log in order")
        try check(!MonitorReducer.prependOlder(older, sessionId: "s", to: &state), "a repeated page changes nothing")
        MonitorReducer.applyEventsMessage(frame([try event("s", 7, ts: "2026-08-07T00:00:07.000Z")]), to: &state)
        try check(state.logEventsBySession["s"]?.compactMap(\.sequence) == [3, 4, 6, 7],
                  "the stream cap trims live events only, never the paged-in ones")
        let foreign = [try event("x", 1)]
        try check(!MonitorReducer.prependOlder(foreign, sessionId: "s", to: &state), "another session's events are ignored")
    }

    private static func reducerCapsPagedEventsAndPrunesUnknownSessions() throws {
        var state = MonitorReducerState()
        let limit = MonitorReducerDefaults.pagedEventLimit
        state.sessions = [try session("s")]
        MonitorReducer.applyEventsMessage(frame([try event("s", limit + 100)]), to: &state)
        var older: [MonitorEvent] = []
        for sequence in 1...(limit + 50) { older.append(try event("s", sequence)) }
        try check(MonitorReducer.prependOlder(older, sessionId: "s", to: &state), "older events must be accepted")
        let paged = state.pagedEventsBySession["s"] ?? []
        try check(paged.count == limit, "paged events cap at \(limit), got \(paged.count)")
        try check(paged.first?.sequence == 51, "the oldest paged events fall off first")
        let log = state.logEventsBySession["s"] ?? []
        try check(log.count == limit + 1 && log.last?.sequence == limit + 100, "the log joins paged and live at the boundary")
        try check(zip(log, log.dropFirst()).allSatisfy { withinSessionEventOrder($0, $1) }, "the joined log stays ordered")

        state.pagedEventsBySession["gone"] = [try event("gone", 1)]
        let snapshot = MonitorSnapshot(
            schemaVersion: MonitorCompatibility.supportedSchemaVersion, monitorApiVersion: "2.0", revision: 7,
            connected: true, streaming: true, error: nil, gateway: nil,
            sessions: state.sessions, eventsBySession: state.eventsBySession,
            historySessions: [], historyEventsBySession: [:], eventLimit: state.eventLimit, tasks: [], inbox: []
        )
        let effect = MonitorReducer.apply(snapshot: snapshot, to: &state)
        try check(state.pagedEventsBySession["gone"] == nil, "a snapshot drops paged events of a session it no longer has")
        try check(state.pagedEventsBySession["s"]?.count == limit, "a known session keeps its paged events")
        try check(effect.logChanged && effect.stateChanged && state.logEventsBySession["gone"] == nil,
                  "pruning rebuilds the log")
    }

    /// The sidecar's snapshot holds only each session's newest events; a poll
    /// must not shrink a bucket the stream grew, and a dropped session goes.
    private static func reducerMergesTruncatedSnapshotsWithoutShrinking() throws {
        var state = MonitorReducerState()
        state.sessions = [try session("s")]
        state.eventsBySession["s"] = try (1...300).map { try event("s", $0) }
        state.eventsBySession["gone"] = [try event("gone", 1)]
        let head = Array(state.eventsBySession["s"]!.suffix(199)) + [try event("s", 301)]
        let snapshot = MonitorSnapshot(
            schemaVersion: MonitorCompatibility.supportedSchemaVersion, monitorApiVersion: "2.0", revision: 9,
            connected: true, streaming: true, error: nil, gateway: nil,
            sessions: state.sessions, eventsBySession: ["s": head],
            historySessions: [], historyEventsBySession: [:], eventLimit: state.eventLimit, tasks: [], inbox: []
        )
        let effect = MonitorReducer.apply(snapshot: snapshot, to: &state)
        let bucket = state.eventsBySession["s"] ?? []
        try check(bucket.count == 301 && bucket.first?.sequence == 1 && bucket.last?.sequence == 301,
                  "a newest-N snapshot merges into the bucket, got \(bucket.count)")
        try check(state.eventsBySession["gone"] == nil, "a session the snapshot does not list is dropped")
        try check(effect.logChanged, "the new event rebuilds the log")
        let again = MonitorReducer.apply(snapshot: snapshot, to: &state)
        try check(!again.logChanged && state.eventsBySession["s"]?.count == 301, "the same revision changes nothing")
    }

    private static func reducerReportsNoChangeForARepeatedStateFrame() throws {
        var state = MonitorReducerState()
        let message: [String: JSONValue] = [
            "kind": .string("state"), "connected": .bool(true), "streaming": .bool(true),
            "sessions": .array([.object(["sessionId": .string("s"), "provider": .string("codex"), "status": .string("running")])]),
            "tasks": .array([]), "inbox": .array([])
        ]
        let first = MonitorReducer.applyStateMessage(message, to: &state)
        try check(first.stateChanged && first.logChanged, "the first frame changes the state")
        let second = MonitorReducer.applyStateMessage(message, to: &state)
        try check(!second.stateChanged && !second.logChanged, "an identical frame must not republish the state")
    }

    private static func reducerDropsHistoryButKeepsLiveOnHistoryCleared() throws {
        var state = MonitorReducerState()
        state.sessions = [try session("live")]
        state.eventsBySession = ["live": [try event("live", 2)]]
        state.historySessions = [try session("old", status: "closed")]
        state.historyEventsBySession = ["old": [try event("old", 1)]]
        state.pagedEventsBySession = ["old": [try event("old", 0)], "live": [try event("live", 1)]]
        MonitorReducer.rebuildLog(in: &state)
        let effect = MonitorReducer.applyStateMessage(["kind": .string("state"), "historyCleared": .bool(true)], to: &state)
        try check(effect.logChanged, "historyCleared must mark the log dirty")
        try check(state.historySessions.isEmpty && state.historyEventsBySession.isEmpty, "history must be gone")
        try check(state.pagedEventsBySession["old"] == nil, "paged events of a history session must be gone")
        try check(state.logEventsBySession["old"] == nil, "the log must drop the history session")
        try check(state.logEventsBySession["live"]?.compactMap(\.sequence) == [1, 2], "live sessions keep all their events")
        try check(state.logSessions.map(\.sessionId) == ["live"], "only live sessions remain listed")
    }

    private static func reducerCapsOrdersAndDeduplicatesArchivedHistoryEvents() throws {
        var history: [MonitorEvent] = []
        for sequence in stride(from: 1500, through: 1, by: -1) {
            history.append(try event("s", sequence))
        }
        var liveEvents: [MonitorEvent] = []
        for sequence in stride(from: 2500, through: 1000, by: -1) {
            liveEvents.append(try event("s", sequence))
        }
        liveEvents.append(try event("s", 2000))

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

private extension GatewaySession {
    /// Enough of the wire record to decode the same session again.
    var payloadForTest: JSONValue {
        .object(["sessionId": .string(sessionId), "provider": .string(provider), "status": .string(status)])
    }
}
