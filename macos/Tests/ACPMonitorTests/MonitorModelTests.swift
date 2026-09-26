import Foundation

@main
enum MonitorModelChecks {
    static func main() throws {
        try snapshotDecodesSessionsEventsTasksAndInbox()
        try dashboardPanelsFoldByWidthAndOpenOnDemand()
        try usageForecastUsesCompletedTurnsAndContextGrowth()
        try sessionNamesFollowTheNamingPolicy()
        try characterizationTracesDecodeExpectedSnapshots()
        try snapshotRejectsUnsupportedSchemaMajorWithoutPartialDecode()
        try compatibilityDistinguishesIncompatibleFromUpdateRequired()
        try semanticVersionsOrderPrereleasesBelowStableReleases()
        try monitorApiVersionParsesMajorMinorAndRejectsMalformedStrings()
        try monitorMetaDecodesGatewayIdentityAndToleratesNullSetupValues()
        try monitorMetaRejectsMissingMonitorApiVersion()
        try monitorClientErrorDecodesCodeAndErrorFromHTTPBody()
        try everyStableFailureCodeCarriesDistinctActionableGuidance()
        try runtimeSplitAnnotationSurfacesAsAWarning()
        try agentCatalogDecodesInstallAndEnabledState()
        try monitoringHookStatusDecodesPerCliState()
        try installedFrontdoorsDecodePrimaryInstalledAndNullEmpty()
        try gatewayConfigDecodesAllControlMetadata()
        try gatewayConfigRepresentsAllKnownSettingIds()
        try gatewayConfigDecodesBothLanguagesAndFallsBackToEnglish()
        try gatewayDisplayUnitsRoundTripExactlyAndFallBackToMilliseconds()
        try retentionPreviewDecodesCountsAndSummarisesOnlyNonZeroOnes()
        try runtimeInspectionAndOperationEnvelopesDecode()
        try sessionConfigDecodesSelectBooleanAndFlattensNestedChoices()
        try sessionConfigPreservesUnknownTypeInsteadOfDropping()
        try sessionConfigDecodesUnavailableSnapshot()
        try petSnapshotMapsGatewayStateAndPendingInbox()
        try petSnapshotSeparatesFrontdoorInstancesAndParsesLegacyTimestamps()
        try petActivityProjectionMapsStatusesToContractStatesAndActions()
        try petStateAndActionsEnvelopesShareMetadataAndSequence()
        try progressOrderingPutsInFlightAgentsFirstThenNewest()
        try petChildEnvironmentAllowsOnlyBenignKeysPlusContractFiles()
        try realtimeSessionsRequireAnActiveFrontdoorIdentity()
        try frontdoorSessionsAggregateWorkersAndExcludeLegacyRecords()
        try frontdoorNamePrefersFolderThenSaneTitle()
        try localFrontdoorIsNotDuplicatedAsAWorker()
        try canonicalEventsDecodeTitleBodyStatusAndStableIds()
        try monitoringHookStatusDecodesLastReceivedAndStateText()
        try historyEndpointsDecode()
        try toolCallsGroupPerTurnAndRequestsStayVisible()
        try permissionOutcomesAndKoreanLabelsRead()
        try sessionCapabilitiesDistinguishBlindFromIdle()
        try eventsFrameUpsertReplacesInsertsAndOrders()
        try eventEqualityIgnoresRawPayloadAndUpsertReportsChange()
        try recentKeysKeepTheOpenOneAndTheNewestFew()
        try selectionFindsAnEventInItsOwnSessionBucket()
        try trailingItemMatchesFullGrouping()
        try sessionUsageDecodesOnlyKnownNumbers()
        try restartBlockersMatchTheSharedGatewayContract()
        try runtimeInspectionSurfacesAPinnedRollback()
        print("Swift model checks passed")
    }

    private static func semanticVersionsOrderPrereleasesBelowStableReleases() throws {
        try check(compareSemanticVersions("0.4.0-beta.1", "0.4.0") == .orderedAscending, "beta.1 must update to the matching stable release")
        try check(compareSemanticVersions("0.4.0", "0.4.0-beta.1") == .orderedDescending, "stable must sort after its prerelease")
        try check(compareSemanticVersions("0.4.0-beta.2", "0.4.0-beta.10") == .orderedAscending, "numeric prerelease identifiers compare numerically")
        try check(compareSemanticVersions("0.4.0-beta", "0.4.0-beta.1") == .orderedAscending, "a shorter equal prerelease sorts first")
        try check(compareSemanticVersions("0.4.0+build.2", "0.4.0+build.1") == .orderedSame, "build metadata must not change precedence")
        try check(compareSemanticVersions("0.3.10", "0.4.0-beta.1") == .orderedAscending, "numeric core ordering must remain semantic")
    }

    private static func petSnapshotMapsGatewayStateAndPendingInbox() throws {
        let sessionValue = JSONValue.object([
            "sessionId": .string("gateway-1"), "acpSessionId": .string("worker-1"),
            "provider": .string("claude"), "model": .string("sonnet"),
            "status": .string("idle"), "cwd": .string("/tmp/project"),
            "opener": .string("codex"),
            "openerInstanceId": .string("codex-main-1"),
            "parentSessionId": .string("codex-parent-1"),
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
        try check(frontdoor?.session == "codex-main-1", "pet should preserve the real frontdoor session id")
        try check(frontdoor?.state == "running", "a pending delegated request should keep the frontdoor active")
        try check(frontdoor?.delegated == false, "frontdoor should not be marked delegated")
        try check(worker?.session == "gateway-1", "pet should use the globally unique Gateway session id")
        try check(worker?.parent == frontdoor?.session, "worker should attach to its frontdoor root")
        try check(worker?.state == "needs_input", "pending inbox should override idle state")
        try check(worker?.inboxPending == 1, "pending inbox count should be shared")
        try check(worker?.delegated == true, "Gateway workers should be marked delegated")
        try check(session.parentSessionId == "codex-parent-1", "session parent relationship should decode")
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

    private static func petActivityProjectionMapsStatusesToContractStatesAndActions() throws {
        func session(id: String, status: String, title: String? = nil) throws -> GatewaySession {
            guard let session = GatewaySession(.object([
                "sessionId": .string(id), "provider": .string("claude"), "model": .string("sonnet"),
                "status": .string(status), "cwd": .string("/tmp/project"),
                "opener": .string("codex"), "openerInstanceId": .string("codex-main-1"),
                "title": .string(title ?? "task \(id)"), "updatedAt": .string("2026-08-07T00:00:00.000Z")
            ])) else { throw CheckError.failed("pet contract fixture creation failed") }
            return session
        }
        let running = try session(id: "s-running", status: "running")
        let waiting = try session(id: "s-waiting", status: "waiting_permission")
        let failed = try session(id: "s-failed", status: "error")
        let cancelled = try session(id: "s-cancelled", status: "cancelled")
        let completed = try session(id: "s-completed", status: "ready")
        let closed = try session(id: "s-closed", status: "closed")
        let offline = try session(
            id: "s-offline", status: "disconnected",
            title: "line one\nline two " + String(repeating: "x", count: 220)
        )

        let projection = PetActivityProjection.make(
            sessions: [running, waiting, failed, cancelled, completed, closed, offline],
            inbox: [], now: Date(timeIntervalSince1970: 0)
        )
        func agent(_ id: String) throws -> PetAgentActivity {
            guard let agent = projection.agents.first(where: { $0.id == id }) else {
                throw CheckError.failed("expected \(id) in the pet activity projection")
            }
            return agent
        }
        let runningAgent = try agent("s-running")
        try check(runningAgent.state == .running, "a running status must map to .running")
        try check(runningAgent.action == .think, "a running worker should think without tool-call evidence")
        let waitingAgent = try agent("s-waiting")
        try check(waitingAgent.state == .waiting, "waiting_permission must map to .waiting")
        try check(waitingAgent.action == .waitForUser, "a waiting worker asks the renderer to wait for the user")
        let failedAgent = try agent("s-failed")
        try check(failedAgent.state == .failed, "an error status must map to .failed")
        try check(failedAgent.action == .error, "a failed worker should play the error action")
        let cancelledAgent = try agent("s-cancelled")
        try check(cancelledAgent.state == .failed, "a cancelled turn must not be reported as .completed")
        try check(cancelledAgent.action != .celebrate, "a cancelled turn must never celebrate")
        let completedAgent = try agent("s-completed")
        try check(completedAgent.state == .completed, "a ready status must map to .completed")
        try check(completedAgent.action == .celebrate, "a completed worker should celebrate")
        let closedAgent = try agent("s-closed")
        try check(closedAgent.state == .offline, "a closed session must map to .offline, matching the legacy Agent Map")

        let offlineAgent = try agent("s-offline")
        try check(offlineAgent.state == .offline, "a disconnected status must map to .offline")
        try check(offlineAgent.action == .disconnect, "an offline worker should disconnect")
        try check((offlineAgent.task?.count ?? 0) <= 200, "task text must be bounded to a display-safe length")
        try check(offlineAgent.task?.contains("\n") == false, "task text must not carry raw newlines")

        let frontdoor = try agent("codex-main-1")
        try check(frontdoor.role == "frontdoor", "the opener should be projected as a frontdoor root")
        try check(frontdoor.parentId == nil, "a frontdoor root has no parent")
        try check(offlineAgent.parentId == "codex-main-1", "workers must link back to their frontdoor root")
        try check(frontdoor.state == .waiting, "a waiting worker should surface as waiting on the frontdoor root")
    }

    private static func petStateAndActionsEnvelopesShareMetadataAndSequence() throws {
        let projection = PetActivityProjection(agents: [
            PetAgentActivity(
                id: "codex-main-1", parentId: nil, role: "frontdoor", provider: "codex",
                engine: "codex-frontdoor", state: .running, action: .think, task: "Ship v1",
                updatedAt: Date(timeIntervalSince1970: 10), source: "gateway",
                cwd: "/tmp/secret-project-path", inboxPending: 3, memberStates: [.running]
            )
        ])
        let generatedAt = Date(timeIntervalSince1970: 100)
        let state = PetStateEnvelope.make(projection: projection, sequence: 7, generatedAt: generatedAt)
        let actions = PetActionsEnvelope.make(projection: projection, sequence: 7, generatedAt: generatedAt)
        try check(state.contract == "pet-state", "the state envelope must declare its contract name")
        try check(actions.contract == "pet-actions", "the actions envelope must declare its contract name")
        try check(state.version == "1.0.0" && actions.version == "1.0.0", "both envelopes must be versioned")
        try check(state.sequence == actions.sequence, "both envelopes from one update must share the same sequence")
        try check(state.generatedAt == actions.generatedAt, "both envelopes from one update must share the same timestamp")
        try check(state.agents.first?.id == actions.actions.first?.id, "both envelopes must describe the same agent id")
        try check(state.agents.first?.parentId == nil, "the root agent has no parent id")
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try check(!encoded.contains("secret-project-path"), "pet-state.json must never leak the agent's raw cwd")
        try check(!encoded.contains("inbox"), "pet-state.json must never leak inbox counts")
    }

    /// The menu-bar status list ranks agents with this shared ordering, so a
    /// running or waiting agent can never be pushed below a stale idle one.
    private static func progressOrderingPutsInFlightAgentsFirstThenNewest() throws {
        func agent(_ id: String, _ state: PetAgentState, _ updatedAt: TimeInterval) -> PetAgentActivity {
            PetAgentActivity(
                id: id, parentId: nil, role: "frontdoor", provider: "codex",
                engine: "codex-frontdoor", state: state, action: .unknown,
                task: id, updatedAt: Date(timeIntervalSince1970: updatedAt), source: "gateway",
                cwd: nil, inboxPending: 0, memberStates: [state]
            )
        }
        let projection = PetActivityProjection(agents: [
            agent("idle-newest", .idle, 900),
            agent("completed", .completed, 500),
            agent("running-oldest", .running, 100),
            agent("waiting", .waiting, 400),
            agent("failed", .failed, 300),
            agent("idle-older", .idle, 200),
            agent("running-newer", .running, 200)
        ])
        let ordered = projection.orderedByProgress.map(\.id)
        try check(
            ordered == [
                "running-newer", "running-oldest", "waiting", "failed",
                "completed", "idle-newest", "idle-older"
            ],
            "in-flight agents must sort ahead of finished and idle ones, newest first within a state"
        )
        try check(
            projection.orderedByProgress.count == projection.agents.count,
            "progress ordering must not drop or duplicate agents"
        )
    }

    private static func petChildEnvironmentAllowsOnlyBenignKeysPlusContractFiles() throws {
        let source = [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "ACP_GATEWAY_CONTROL_TOKEN": "secret-token",
            "MONITOR_API_TOKEN": "another-secret",
            "SOME_RANDOM_VAR": "leak-me"
        ]
        let environment = PetChildEnvironment.make(
            from: source, stateFilePath: "/tmp/pet-state.json", actionsFilePath: "/tmp/pet-actions.json"
        )
        try check(environment["HOME"] == "/Users/test", "a benign HOME should pass through")
        try check(environment["PATH"] == "/usr/bin", "a benign PATH should pass through")
        try check(environment["ACP_GATEWAY_CONTROL_TOKEN"] == nil, "the Gateway control token must never reach the renderer")
        try check(environment["MONITOR_API_TOKEN"] == nil, "monitor auth must never reach the renderer")
        try check(environment["SOME_RANDOM_VAR"] == nil, "arbitrary app environment must not leak to the renderer")
        try check(environment["PET_STATE_FILE"] == "/tmp/pet-state.json", "the state file path must be provided")
        try check(environment["PET_ACTIONS_FILE"] == "/tmp/pet-actions.json", "the actions file path must be provided")
    }

    private static func snapshotDecodesSessionsEventsTasksAndInbox() throws {
        let fixtureURL = repositoryRoot().appendingPathComponent("sidecar/test/fixtures/monitor-snapshot-v2.json")
        // `_input` is the Node test's construction input; the rest is the wire
        // payload. Unknown top-level keys must not disturb decoding.
        let snapshot = try MonitorSnapshot.decode(try Data(contentsOf: fixtureURL))
        try check(snapshot.schemaVersion == 2, "snapshot should decode the schema version")
        try check(snapshot.monitorApiVersion == "2.0", "snapshot should decode the monitor API version")
        try check(snapshot.revision == 13, "snapshot should decode the shared state revision")
        try check(snapshot.connected, "snapshot should be connected")
        try check(snapshot.streaming, "snapshot should decode the streaming state")
        try check(snapshot.eventLimit == 2_000, "snapshot should decode the per-session event limit")
        try check(snapshot.tasks.first?.id == "t1", "task decode failed")
        try check(snapshot.inbox.first?.id == "i1", "inbox decode failed")

        guard let session = snapshot.sessions.first, session.sessionId == "s1" else {
            throw CheckError.failed("session decode failed")
        }
        try check(session.model == "gpt-5.6", "a real model id should decode")
        try check(session.capabilities == ["status", "timeline", "tools", "thinking", "permission", "usage"],
                  "capabilities should decode")
        try check(!session.usagePartial, "a missing usagePartial means complete totals")
        guard let usage = session.usage else { throw CheckError.failed("session usage should decode") }
        try check(usage.inputTokens == 1_200 && usage.outputTokens == 80 && usage.totalTokens == 1_280,
                  "usage token counts should decode")
        try check(usage.cacheReadTokens == 1_000 && usage.reasoningTokens == 20, "cache/reasoning tokens should decode")
        try check(usage.cacheWriteTokens == nil && usage.costUsd == nil, "a null usage field must stay nil, never zero")
        try check(usage.contextWindow == 258_400, "context window should decode")
        try check(abs((usage.contextFraction ?? 0) - 1_200.0 / 258_400.0) < 0.000_001, "context fraction should be used/window")

        let events = snapshot.eventsBySession["s1"] ?? []
        try check(events.map(\.kind) == ["turn_start", "agent_message", "tool_call", "permission_request"],
                  "events should decode as canonical kinds in ts/sequence order: \(events.map(\.kind))")
        try check(events.map(\.sequence) == [1, 2, 3, 4], "monitor sequences should decode")
        try check(events.first?.id == "s1#turn:turn-1" && events.first?.key == "turn:turn-1", "stable ids should decode")
        try check(events.first?.body == "work", "turn_start body is the prompt")
        try check(events[1].body == "checking now", "the sidecar's merged message body is read verbatim")
        let tool = events[2]
        try check(tool.title == "Read: README.md" && tool.body == "# Project", "a tool call's title/body come from the sidecar")
        try check(tool.status == "completed" && !tool.isInFlight, "a finished tool call carries its terminal status")
        try check(tool.toolCallId == "call-1" && tool.endedAt == "2026-08-07T00:00:03.000Z", "tool call identity/end should decode")
        try check(tool.detail["input"]?.stringValue == #"{"path":"README.md"}"#, "tool detail should decode")
        try check(tool.sources == ["gateway"], "sources should decode")
        try check(events[3].status == "pending" && events[3].isInFlight, "an unanswered permission request is pending")
        try check(events[3].title == "Write README.md", "a permission request is titled by its tool")

        try check(snapshot.historySessions.first?.sessionId == "old", "history session decode failed")
        try check(snapshot.historySessions.first?.model == nil, "a session without a model decodes nil")
        try check(snapshot.historySessions.first?.usage == nil, "a session without usage decodes nil")
        let history = snapshot.historyEventsBySession["old"]?.first
        try check(history?.kind == "turn_end" && history?.status == "completed", "history event decode failed")
        try check(history?.detail["stopReason"]?.stringValue == "end_turn", "turn_end detail should keep the stop reason")
    }

    /// Reads the same ordered NDJSON characterization fixtures the Node
    /// replay harness executes. Since v2 the app never sees the raw Gateway
    /// events those traces feed Node (the sidecar normalizes them), so Swift
    /// decodes each trace's expected — and any checkpoint — snapshot with the
    /// production decoder and runs the same `MonitorSelection` /
    /// `MonitorStreamNotice` helpers `AppModel` calls on the result.
    private static func characterizationTracesDecodeExpectedSnapshots() throws {
        let traceRoot = repositoryRoot().appendingPathComponent("sidecar/test/fixtures/monitor-traces")
        let traceFiles = [
            "cold-start-gateway-meta-delay.ndjson",
            "frontdoor-disappears.ndjson",
            "selection-reset.ndjson",
            "observer-buffer-overflow.ndjson",
            "sidecar-reconnect.ndjson",
            "legacy-1.3.2-daemon.ndjson",
            "event-flood.ndjson",
            "subscription-gap.ndjson"
        ]

        for name in traceFiles {
            try replayCharacterizationTrace(
                name: name,
                url: traceRoot.appendingPathComponent(name)
            )
        }
    }

    private static func replayCharacterizationTrace(name: String, url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let records = try text.split(whereSeparator: { $0.isNewline }).map {
            try decodeJSONValue(Data($0.utf8))
        }
        guard let meta = records.first?.objectValue,
              meta.string("kind") == "meta",
              meta.int("traceVersion") == 2,
              let expected = records.last?.objectValue,
              expected.string("kind") == "expected",
              let snapshotValue = expected["snapshot"] else {
            throw CheckError.failed("malformed characterization trace: \(name)")
        }

        var delayedMeta: MonitorMeta?
        var selectedFrontdoorId: String?
        var cursorTruncated = false

        for stepValue in records.dropFirst().dropLast() {
            guard let step = stepValue.objectValue, let kind = step.string("kind") else {
                throw CheckError.failed("malformed step in \(name)")
            }
            switch kind {
            case "set_sessions", "state":
                // Session records are the same shape on both sides of the
                // sidecar, so these inputs still go through the decoder.
                let sessions = try decodeTraceSessions(step.array("sessions") ?? [], name: name)
                if kind == "set_sessions", selectedFrontdoorId == nil {
                    selectedFrontdoorId = sessions.compactMap(\.openerInstanceId).first
                }
            case "checkpoint":
                if let checkpoint = step["snapshot"] {
                    _ = try decodeTraceSnapshot(checkpoint, name: name)
                }
                if let metaValue = step["meta"] {
                    delayedMeta = try decodeTraceMeta(metaValue, name: name)
                    try check(delayedMeta?.gatewayIdentity.gatewayVersion == nil,
                              "cold-start meta must decode a null gateway identity in \(name)")
                    try check(delayedMeta?.gatewayIdentity.gatewayBuildId == nil,
                              "cold-start meta must tolerate null setup values in \(name)")
                }
            case "initial_subscription", "restored_subscription":
                if let args = step.object("args") {
                    try check(args.bool("includeThoughts") == true && args.bool("includeToolEvents") == true,
                              "subscribe args must match production observer in \(name)")
                }
                if let truncated = step.object("cursorTruncated") {
                    cursorTruncated = truncated.values.contains { $0.boolValue == true }
                }
            case "push_event", "replay_event", "socket_flow", "subscription_gap",
                 "set_gateway", "set_tasks", "set_inbox", "reconciled":
                // Raw Gateway input for the Node runner; the app only ever
                // receives the canonical result in the expected snapshot.
                break
            default:
                throw CheckError.failed("unknown step \(kind) in \(name)")
            }
        }

        let snapshot = try decodeTraceSnapshot(snapshotValue, name: name)
        // The unattributed-worker group holds sessions with no Frontdoor; it
        // is shown, but it is not a Frontdoor the projection names.
        let grouped = FrontdoorSession.make(sessions: snapshot.historySessions + snapshot.sessions)
        let snapshotFrontdoors = Set(grouped.filter { !$0.isUnattributed }.map(\.id))
        if name == "legacy-1.3.2-daemon.ndjson" {
            try check(grouped.contains { $0.isUnattributed && !$0.workers.isEmpty },
                      "a worker without an opener is listed under 연결 미확인 Worker, not dropped")
        }
        let snapshotEvents = Set(
            snapshot.eventsBySession.values.joined().map { "\($0.sessionId):\($0.sequence ?? -1)" }
            + snapshot.historyEventsBySession.values.joined().map { "\($0.sessionId):\($0.sequence ?? -1)" }
        )
        let projection = expected.object("projection") ?? [:]
        let expectedFrontdoors = Set((projection.array("frontdoorIds") ?? []).compactMap { $0.stringValue })
        let expectedEvents = Set((projection.array("eventRefs") ?? []).compactMap { $0.stringValue })
        try check(snapshotFrontdoors == expectedFrontdoors,
                  "Frontdoor projection diverged for \(name): \(snapshotFrontdoors) != \(expectedFrontdoors)")
        try check(snapshotEvents == expectedEvents,
                  "event projection diverged for \(name): \(snapshotEvents) != \(expectedEvents)")
        for bucket in Array(snapshot.eventsBySession.values) + Array(snapshot.historyEventsBySession.values) {
            try check(Set(bucket.map(\.id)).count == bucket.count, "event ids must be unique per session in \(name)")
            try check(zip(bucket, bucket.dropFirst()).allSatisfy { !withinSessionEventOrder($1, $0) },
                      "decoded buckets must be in ts/sequence order in \(name)")
        }
        if snapshot.sessions.isEmpty && !snapshot.historySessions.isEmpty {
            try check(!FrontdoorSession.make(sessions: snapshot.historySessions).isEmpty || expectedFrontdoors.isEmpty,
                      "history-only Frontdoor must stay visible in \(name)")
            try check(!snapshot.historyEventsBySession.values.joined().isEmpty || expectedEvents.isEmpty,
                      "history-only log events must stay visible in \(name)")
        }

        if let declaredFrontdoor = projection.string("selectedFrontdoorId"),
           let declaredRef = projection.string("selectedEventRef") {
            // eventRefs are `sessionId:sequence`; selection works on stable ids.
            let allEvents = Array(snapshot.eventsBySession.values.joined()) + Array(snapshot.historyEventsBySession.values.joined())
            guard let declaredEvent = allEvents.first(where: { "\($0.sessionId):\($0.sequence ?? -1)" == declaredRef })?.id else {
                throw CheckError.failed("selectedEventRef \(declaredRef) is not in the snapshot for \(name)")
            }
            let kept = MonitorSelection.reconcile(
                selectedFrontdoorId: declaredFrontdoor,
                selectedEventId: declaredEvent,
                liveSessions: snapshot.sessions,
                historySessions: snapshot.historySessions,
                liveEvents: snapshot.eventsBySession,
                historyEvents: snapshot.historyEventsBySession
            )
            try check(kept.frontdoorId == declaredFrontdoor,
                      "MonitorSelection must keep a history-only Frontdoor after live sessions disappear in \(name)")
            try check(kept.eventId == declaredEvent,
                      "MonitorSelection must keep a history-only event after live sessions disappear in \(name)")
        } else if let declared = projection.string("selectedFrontdoorId") ?? selectedFrontdoorId {
            try check(snapshotFrontdoors.contains(declared),
                      "selected history-only Frontdoor is not selectable after live sessions disappear in \(name)")
        }

        if let expectedMeta = expected["meta"] {
            let decoded = try decodeTraceMeta(expectedMeta, name: name)
            try check(decoded.gatewayIdentity.rootId == meta.string("rootId"),
                      "final MonitorMeta rootId diverged in \(name)")
            try check(decoded.gatewayIdentity.gatewayVersion != nil,
                      "final MonitorMeta must decode setup identity in \(name)")
            try check(delayedMeta != nil, "null gateway identity meta must decode before setup in \(name)")
            if let gateway = snapshot.gateway?.objectValue {
                try check(decoded.gatewayIdentity.gatewayVersion == gateway.string("gatewayVersion"),
                          "MonitorMeta gatewayVersion must follow setup in \(name)")
                try check(decoded.gatewayIdentity.gatewayBuildId == gateway.string("gatewayBuildId"),
                          "MonitorMeta gatewayBuildId must follow setup in \(name)")
            }
        }

        if let transport = expected.object("transport") {
            if let sseState = transport.object("sseState") {
                try check(sseState.string("kind") == "state",
                          "subscription_error must map to SSE kind=state in \(name)")
                try check(sseState.bool("streaming") == false,
                          "subscription_error SSE must pause streaming in \(name)")
                try check(sseState.bool("connected") == true,
                          "subscription_error SSE must keep connected in \(name)")
                try check(sseState.string("error") == "Gateway subscriber is too slow",
                          "subscription_error SSE must carry the socket error in \(name)")
                try check(transport["noticeWrites"] == nil,
                          "subscription_error must not be characterized as a notice write count")
                let expectedNotice = expected.string("pausedSubscriptionNotice") ?? sseState.string("error")
                let notice = MonitorStreamNotice.forPausedSubscription(
                    connected: sseState.bool("connected") ?? false,
                    streaming: sseState.bool("streaming"),
                    error: sseState.string("error")
                )
                try check(notice == expectedNotice,
                          "connected streaming=false state must record exactly one overflow notice in \(name)")
                guard let notice else {
                    throw CheckError.failed("paused-subscription notice is missing in \(name)")
                }
                var noticeLog: [NoticeEntry] = []
                NoticeEntry.record(notice, at: Date(timeIntervalSince1970: 1), into: &noticeLog)
                NoticeEntry.record(notice, at: Date(timeIntervalSince1970: 2), into: &noticeLog)
                try check(noticeLog.count == 1 && noticeLog[0].text == notice && noticeLog[0].count == 2,
                          "consecutive overflow notices must collapse to one row with count=2 in \(name)")
                NoticeEntry.record("Gateway 연결 끊김", at: Date(timeIntervalSince1970: 3), into: &noticeLog)
                try check(noticeLog.count == 2 && noticeLog[0].text == "Gateway 연결 끊김" && noticeLog[0].count == 1,
                          "a distinct notice must become the new first row in \(name)")
                try check(noticeLog[1].text == notice && noticeLog[1].count == 2,
                          "the collapsed overflow row must stay under a distinct newer notice in \(name)")
                try check(
                    MonitorStreamNotice.forPausedSubscription(
                        connected: false, streaming: false, error: sseState.string("error")
                    ) == nil,
                    "a disconnected state must not use the paused-subscription notice path in \(name)"
                )
                try check(
                    MonitorStreamNotice.forPausedSubscription(
                        connected: true, streaming: true, error: sseState.string("error")
                    ) == nil,
                    "a still-streaming state must not record an overflow notice in \(name)"
                )
                try check(
                    MonitorStreamNotice.forPausedSubscription(
                        connected: true, streaming: false, error: nil
                    ) == nil,
                    "a streaming pause without an error must not record an overflow notice in \(name)"
                )
            }
            if transport.object("cursorTruncated") != nil {
                try check(cursorTruncated, "reconnect fixture must include cursorTruncated=true in \(name)")
                try check((transport.array("receivedTypes") ?? []).contains { value in
                    value.stringValue == "subscription_replay_truncated"
                },
                          "cursorTruncated=true must surface subscription_replay_truncated in \(name)")
            }
            if let args = transport.object("subscribeArgs") {
                try check(args.bool("includeThoughts") == true && args.bool("includeToolEvents") == true,
                          "restored subscribe args must match production observer in \(name)")
            }
        }
    }

    /// Characterization traces may assert a focused partial snapshot. Adds
    /// only the required wire envelope, then decodes with production code and
    /// checks no event was silently dropped by the decoder.
    private static func decodeTraceSnapshot(_ value: JSONValue, name: String) throws -> MonitorSnapshot {
        guard var object = value.objectValue else {
            throw CheckError.failed("trace snapshot is not an object in \(name)")
        }
        object["schemaVersion"] = object["schemaVersion"] ?? .number(2)
        object["monitorApiVersion"] = object["monitorApiVersion"] ?? .string("2.0")
        let data = try JSONSerialization.data(withJSONObject: JSONValue.object(object).foundationValue)
        let snapshot = try MonitorSnapshot.decode(data)
        for field in ["events", "historyEvents"] {
            let raw = (object.object(field) ?? [:]).values.reduce(0) { $0 + ($1.arrayValue?.count ?? 0) }
            let decoded = (field == "events" ? snapshot.eventsBySession : snapshot.historyEventsBySession)
                .values.reduce(0) { $0 + $1.count }
            try check(raw == decoded, "every canonical \(field) entry must decode in \(name): \(decoded)/\(raw)")
        }
        return snapshot
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func decodeTraceSessions(_ values: [JSONValue], name: String) throws -> [GatewaySession] {
        try values.map { value in
            guard let session = GatewaySession(value) else {
                throw CheckError.failed("session did not decode in \(name)")
            }
            return session
        }
    }

    private static func decodeTraceMeta(_ value: JSONValue, name: String) throws -> MonitorMeta {
        let data = try JSONSerialization.data(withJSONObject: value.foundationValue)
        return try MonitorMeta.decode(data)
    }

    private static func snapshotRejectsUnsupportedSchemaMajorWithoutPartialDecode() throws {
        let data = Data(#"""
        {
          "schemaVersion":3,
          "monitorApiVersion":"2.0",
          "connected":true,
          "sessions":[{"sessionId":"s1","provider":"codex","status":"running","cwd":"/tmp/project"}]
        }
        """#.utf8)
        do {
            _ = try MonitorSnapshot.decode(data)
            throw CheckError.failed("an unsupported schema major must be rejected, not partially decoded")
        } catch let error as MonitorDecodeError {
            guard case .updateRequired = error else {
                throw CheckError.failed("a well-formed but unsupported schema major should use the stable update-required error")
            }
            try check(error.stableCode == "monitor_update_required", "the stable code should be monitor_update_required")
        }

        // A missing monitorApiVersion is a malformed/missing contract, not a
        // recognizable-but-outdated one: it must reject as incompatible, not
        // update-required.
        let missingApiVersion = Data(#"{"schemaVersion":2,"connected":true,"sessions":[]}"#.utf8)
        do {
            _ = try MonitorSnapshot.decode(missingApiVersion)
            throw CheckError.failed("a missing monitorApiVersion must be rejected, not defaulted")
        } catch let error as MonitorDecodeError {
            guard case .apiIncompatible = error else {
                throw CheckError.failed("a missing monitorApiVersion should use the stable api-incompatible error")
            }
            try check(error.stableCode == "monitor_api_incompatible", "the stable code should be monitor_api_incompatible")
        }
    }

    /// `MonitorCompatibility.validate` must distinguish a malformed/missing
    /// version field (this build cannot tell what it's looking at) from a
    /// well-formed field naming an unsupported version (this build knows
    /// exactly what it's looking at, and knows it's too old for it).
    private static func compatibilityDistinguishesIncompatibleFromUpdateRequired() throws {
        let malformedCases = [
            #"{"monitorApiVersion":"2.0"}"#, // missing schemaVersion entirely
            #"{"schemaVersion":"2","monitorApiVersion":"2.0"}"#, // schemaVersion is not a number
            #"{"schemaVersion":2}"#, // missing monitorApiVersion entirely
            #"{"schemaVersion":2,"monitorApiVersion":"bad"}"#, // unparseable version string
            #"{"schemaVersion":2,"monitorApiVersion":"2"}"# // missing minor component
        ]
        for json in malformedCases {
            do {
                _ = try MonitorMeta.decode(Data(json.utf8))
                throw CheckError.failed("expected \(json) to be rejected as api-incompatible")
            } catch let error as MonitorDecodeError {
                guard case .apiIncompatible = error else {
                    throw CheckError.failed("\(json) should decode a malformed/missing contract as api-incompatible, got \(error)")
                }
                try check(error.stableCode == "monitor_api_incompatible", "stable code mismatch for \(json)")
            }
        }

        let updateRequiredCases = [
            #"{"schemaVersion":1,"monitorApiVersion":"2.0"}"#, // a v1 monitor: canonical events are v2-only
            #"{"schemaVersion":3,"monitorApiVersion":"2.0"}"#, // well-formed but unsupported schema major
            #"{"schemaVersion":2,"monitorApiVersion":"1.0"}"#, // a v1 API behind a v2 schema
            #"{"schemaVersion":2,"monitorApiVersion":"3.0"}"# // well-formed but unsupported API major
        ]
        for json in updateRequiredCases {
            do {
                _ = try MonitorMeta.decode(Data(json.utf8))
                throw CheckError.failed("expected \(json) to be rejected as update-required")
            } catch let error as MonitorDecodeError {
                guard case .updateRequired = error else {
                    throw CheckError.failed("\(json) should decode a well-formed but unsupported version as update-required, got \(error)")
                }
                try check(error.stableCode == "monitor_update_required", "stable code mismatch for \(json)")
            }
        }
    }

    private static func monitorApiVersionParsesMajorMinorAndRejectsMalformedStrings() throws {
        try check(MonitorApiVersion("1.0")?.major == 1, "1.0 should parse as major 1")
        try check(MonitorApiVersion("1.0")?.minor == 0, "1.0 should parse as minor 0")
        try check(MonitorApiVersion("1.5")?.minor == 5, "an additive minor version should still parse")
        try check(MonitorApiVersion("2.0")?.major == 2, "a future major should still parse (compatibility is checked separately)")
        try check(MonitorApiVersion("bad") == nil, "a malformed version string must not parse")
        try check(MonitorApiVersion("1") == nil, "a version string missing its minor component must not parse")
        try check(MonitorApiVersion("-1.0") == nil, "a negative major version must not parse")
        try check(MonitorApiVersion("1.-1") == nil, "a negative minor version must not parse")
    }

    private static func monitorMetaDecodesGatewayIdentityAndToleratesNullSetupValues() throws {
        let data = Data(#"""
        {
          "schemaVersion":2,
          "monitorApiVersion":"2.1",
          "sidecarVersion":"0.4.0",
          "sidecarBuildId":"sidecar-build",
          "gatewayIdentity":{"rootId":"root-1","gatewayApiVersion":1,"gatewayVersion":null,"gatewayBuildId":null},
          "capabilities":{"agentUpdates":true}
        }
        """#.utf8)
        let meta = try MonitorMeta.decode(data)
        try check(meta.schemaVersion == 2, "meta should decode the schema version")
        try check(meta.monitorApiVersion == "2.1", "an additive minor version must stay compatible")
        try check(meta.sidecarVersion == "0.4.0", "meta should decode the sidecar version")
        try check(meta.sidecarBuildId == "sidecar-build", "meta should decode the sidecar build id")
        try check(meta.gatewayIdentity.rootId == "root-1", "meta should decode the gateway identity root id")
        try check(meta.gatewayIdentity.gatewayApiVersion == 1, "meta should decode the gateway API version")
        try check(meta.gatewayIdentity.gatewayVersion == nil, "a missing Gateway setup value should decode as nil, not crash")
        try check(meta.gatewayIdentity.gatewayBuildId == nil, "a missing Gateway setup value should decode as nil, not crash")
        try check(meta.capabilities.objectValue?.bool("agentUpdates") == true, "capabilities should be preserved as additive JSON")
    }

    private static func monitorMetaRejectsMissingMonitorApiVersion() throws {
        let data = Data(#"{"schemaVersion":2,"gatewayIdentity":{},"capabilities":{}}"#.utf8)
        do {
            _ = try MonitorMeta.decode(data)
            throw CheckError.failed("a missing monitorApiVersion must be rejected, not defaulted")
        } catch let error as MonitorDecodeError {
            guard case .apiIncompatible = error else {
                throw CheckError.failed("a missing monitorApiVersion should use the stable api-incompatible error")
            }
            try check(error.stableCode == "monitor_api_incompatible", "the stable code should be monitor_api_incompatible")
        }
    }

    private static func monitorClientErrorDecodesCodeAndErrorFromHTTPBody() throws {
        let data = Data(#"{"error":"unauthorized","code":"monitor_unauthorized"}"#.utf8)
        let error = MonitorClientError.decode(data: data, statusCode: 401)
        try check(error.code == "monitor_unauthorized", "typed error should retain the stable HTTP code")
        try check(error.errorDescription == "unauthorized", "typed error should keep the readable message")

        let fallback = MonitorClientError.decode(data: Data(), statusCode: 500)
        try check(fallback.code == nil, "a body without a code should decode with no code rather than crash")
        try check(fallback.errorDescription == "Monitor request failed (HTTP 500)", "a missing error body should fall back to a readable status message")

        // An explicit server code for a blocked restart must be preserved
        // verbatim, never erased or re-inferred client-side.
        let restartBlocked = MonitorClientError.decode(
            data: Data(#"{"error":"Gateway를 안전하게 재시작할 수 없습니다: 진행 중 세션 1개","code":"monitor_restart_blocked"}"#.utf8),
            statusCode: 409
        )
        try check(restartBlocked.code == "monitor_restart_blocked", "an explicit restart-blocked server code must be preserved")
        try check(restartBlocked.errorDescription == "Gateway를 안전하게 재시작할 수 없습니다: 진행 중 세션 1개", "the blocker detail message must be preserved")
    }

    private static func realtimeSessionsRequireAnActiveFrontdoorIdentity() throws {
        func session(id: String, status: String, instanceId: String?, model: String? = nil) throws -> GatewaySession {
            var value: [String: JSONValue] = [
                "sessionId": .string(id), "provider": .string("codex"),
                "status": .string(status), "cwd": .string("/tmp/project"),
                "opener": .string("codex")
            ]
            if let instanceId { value["openerInstanceId"] = .string(instanceId) }
            if let model { value["model"] = .string(model) }
            guard let decoded = GatewaySession(.object(value)) else {
                throw CheckError.failed("realtime fixture creation failed")
            }
            return decoded
        }

        let running = try session(id: "running", status: "running", instanceId: "main-1")
        let idle = try session(id: "idle", status: "idle", instanceId: "main-1")
        let legacy = try session(id: "legacy", status: "running", instanceId: nil)
        let review = try session(id: "review", status: "running", instanceId: "main-1", model: "codex-auto-review")
        try check(running.isRealtimeVisible,
                  "an active worker with a real frontdoor id should be visible")
        try check(!idle.isRealtimeVisible,
                  "an idle mapped worker should leave the realtime view")
        try check(!legacy.isRealtimeVisible,
                  "a worker without a frontdoor session id must not create a synthetic live root")
        try check(review.isInternalReview,
                  "auto-review must be identifiable as internal review noise")
    }

    private static func frontdoorSessionsAggregateWorkersAndExcludeLegacyRecords() throws {
        func session(id: String, status: String, instanceId: String?, opener: String = "codex") throws -> GatewaySession {
            var value: [String: JSONValue] = [
                "sessionId": .string(id), "provider": .string("codex"),
                "status": .string(status), "cwd": .string("/tmp/project"),
                "opener": .string(opener), "updatedAt": .string("2026-08-07T00:00:00Z")
            ]
            if let instanceId { value["openerInstanceId"] = .string(instanceId) }
            guard let decoded = GatewaySession(.object(value)) else {
                throw CheckError.failed("frontdoor aggregation fixture creation failed")
            }
            return decoded
        }

        let frontdoors = FrontdoorSession.make(sessions: [
            try session(id: "worker-1", status: "running", instanceId: "main-1"),
            try session(id: "worker-2", status: "idle", instanceId: "main-1"),
            try session(id: "worker-3", status: "idle", instanceId: "main-2", opener: "grok"),
            try session(id: "legacy", status: "running", instanceId: nil)
        ])
        let real = frontdoors.filter { !$0.isUnattributed }
        try check(real.count == 2, "Dashboard should list Frontdoors, not mapped Worker sessions")
        let codex = frontdoors.first { $0.id == "main-1" }
        try check(codex?.workers.count == 2, "workers with the same Frontdoor id should aggregate")
        try check(codex?.activeWorkerCount == 1, "Frontdoor activity should come from its current workers")
        try check(!frontdoors.contains(where: { $0.id == "legacy" }), "a session without a Frontdoor id is never promoted to one")
        // Policy (docs/ux-policy.md §1): never a Frontdoor, but never hidden.
        let orphans = frontdoors.first(where: \.isUnattributed)
        try check(orphans?.workers.map(\.sessionId) == ["legacy"] && orphans?.displayName == "연결 미확인 Worker",
                  "a worker without an opener is listed under 연결 미확인 Worker")
    }

    /// The Frontdoor name is its working folder first; a title is only used
    /// without a folder, and never when it is the transient tool-call text a
    /// local session parks in its title.
    private static func frontdoorNamePrefersFolderThenSaneTitle() throws {
        func frontdoor(title: String?, cwd: String) throws -> FrontdoorSession {
            var root: [String: JSONValue] = [
                "sessionId": .string("root"), "provider": .string("codex"),
                "status": .string("running"), "cwd": .string(cwd), "role": .string("frontdoor"),
                "opener": .string("codex"), "openerInstanceId": .string("main-1"),
                "updatedAt": .string("2026-08-07T00:00:00Z")
            ]
            if let title { root["title"] = .string(title) }
            guard let session = GatewaySession(.object(root)),
                  let made = FrontdoorSession.make(sessions: [session]).first else {
                throw CheckError.failed("frontdoor name fixture creation failed")
            }
            return made
        }
        // Folder wins even when a title is present; a real title is used only
        // without a folder; tool-call text is never a name.
        let folderWithTitle = try frontdoor(title: "리팩터링 작업", cwd: "/Users/x/Documents/proj")
        let titleNoFolder = try frontdoor(title: "리팩터링 작업", cwd: "/")
        let junkTitle = try frontdoor(title: "custom_tool_call/exec", cwd: "/")
        let folderOnly = try frontdoor(title: nil, cwd: "/Users/x/Documents/proj")
        let bare = try frontdoor(title: nil, cwd: "/")
        try check(folderWithTitle.displayName == "proj", "the working folder names the Frontdoor even when a title exists")
        try check(titleNoFolder.displayName == "리팩터링 작업", "without a folder a sane title names the Frontdoor")
        try check(junkTitle.displayName == "이름 없는 작업", "a tool-call title is rejected as a name; the provider is the icon")
        try check(folderOnly.displayName == "proj", "the working folder names the Frontdoor")
        try check(bare.displayName == "이름 없는 작업", "with neither, a neutral name; the provider is the icon")
    }

    private static func localFrontdoorIsNotDuplicatedAsAWorker() throws {
        func session(
            id: String,
            provider: String = "codex",
            status: String = "running",
            source: String? = nil,
            role: String? = nil,
            model: String? = nil
        ) throws -> GatewaySession {
            var value: [String: JSONValue] = [
                "sessionId": .string(id), "provider": .string(provider),
                "status": .string(status), "cwd": .string("/tmp/local-project"),
                "opener": .string("codex"), "openerInstanceId": .string("main-local"),
                "title": .string(id), "updatedAt": .string("2026-08-07T00:00:00Z")
            ]
            if let source { value["source"] = .string(source) }
            if let role { value["role"] = .string(role) }
            if let model { value["model"] = .string(model) }
            guard let decoded = GatewaySession(.object(value)) else {
                throw CheckError.failed("local frontdoor fixture creation failed")
            }
            return decoded
        }

        let root = try session(id: "local:codex:main-local", source: "local", role: "frontdoor", model: "gpt-local")
        let gatewayWorker = try session(id: "gateway-worker", provider: "claude", model: "sonnet")
        let localWorker = try session(id: "local:codex:child", source: "local", role: "worker")
        try check(root.isFrontdoorRecord && root.source == "local", "local frontdoor metadata should decode")
        try check(!gatewayWorker.isFrontdoorRecord && gatewayWorker.source == "gateway", "Gateway records should keep worker defaults")

        let frontdoors = FrontdoorSession.make(sessions: [root, gatewayWorker, localWorker])
        try check(frontdoors.count == 1, "a local root and its workers should share one Frontdoor")
        try check(frontdoors[0].root?.sessionId == root.sessionId, "the local record should become the real Frontdoor root")
        try check(frontdoors[0].workers.count == 2, "the Frontdoor root must not count as a worker")
        try check(frontdoors[0].members.count == 3 && frontdoors[0].isActive, "root activity should keep the Frontdoor active")

        let pet = PetSnapshot.make(sessions: [root, gatewayWorker], inbox: [], now: Date(timeIntervalSince1970: 0))
        try check(pet.sessions.count == 2, "Pet should receive one real root and one worker without a synthetic duplicate")
        let petRoot = pet.sessions.first { $0.role == "frontdoor" }
        try check(petRoot?.session == "main-local", "Pet root should use the raw Frontdoor identity")
        try check(petRoot?.engine == "gpt-local", "Pet root should preserve the local model")
        try check(!pet.sessions.contains(where: { $0.role == "worker" && $0.session == root.sessionId }), "local root must not be emitted as a worker")
    }

    /// G6: 인증 실패, 미설치, API 비호환, 업데이트 필요, restart blocked가
    /// 서로 다른, 실행 가능한 안내로 구분되어야 한다.
    private static func everyStableFailureCodeCarriesDistinctActionableGuidance() throws {
        let codes = [
            "monitor_not_installed",
            "monitor_api_incompatible",
            "monitor_update_required",
            "monitor_unauthorized",
            "monitor_restart_blocked"
        ]
        var seen = Set<String>()
        for code in codes {
            guard let guidance = monitorFailureGuidance(code: code) else {
                throw CheckError.failed("stable code \(code) must map to user guidance")
            }
            try check(seen.insert(guidance).inserted, "guidance for \(code) must be distinct, not shared")
        }
        try check(monitorFailureGuidance(code: "monitor_internal") == nil, "internal errors carry no user action")
        try check(monitorFailureGuidance(code: nil) == nil, "an uncoded failure has no synthetic guidance")

        // The client-side classification feeding those codes.
        try check(MonitorDecodeError.updateRequired("x").stableCode == "monitor_update_required", "update-required decode failures must keep their code")
        try check(MonitorDecodeError.apiIncompatible("x").stableCode == "monitor_api_incompatible", "incompatible decode failures must keep their code")
    }

    private static func runtimeSplitAnnotationSurfacesAsAWarning() throws {
        let split = JSONValue.object([
            "gatewayVersion": .string("1.3.1"),
            "runtimeSplit": .object([
                "daemonRuntimeRoot": .string("/Users/x/dev/checkout"),
                "monitorRuntimeRoot": .string("/Users/x/.acp-gateway/runtime/versions/1.3.1-new")
            ])
        ])
        guard let warning = runtimeSplitWarning(gateway: split) else {
            throw CheckError.failed("an annotated split must produce a user warning")
        }
        try check(warning.contains("/Users/x/dev/checkout"), "the warning must name the foreign runtime root")
        let buildSplit = JSONValue.object([
            "runtimeSplit": .object([
                "daemonBuildId": .string("old"),
                "monitorBuildId": .string("new")
            ])
        ])
        try check(runtimeSplitWarning(gateway: buildSplit)?.contains("old") == true, "a build-id split must surface as a warning")
        try check(runtimeSplitWarning(gateway: .object(["gatewayVersion": .string("1.3.1")])) == nil, "no annotation, no warning")
        try check(runtimeSplitWarning(gateway: nil) == nil, "no gateway info, no warning")
    }

    private static func usageForecastUsesCompletedTurnsAndContextGrowth() throws {
        func turn(_ id: String, running: Bool = false, total: Double?, context: Double?) -> JSONValue {
            var object: [String: JSONValue] = ["turnId": .string(id), "running": .bool(running)]
            if let total { object["totalTokens"] = .number(total) }
            if let context { object["contextUsed"] = .number(context) }
            return .object(object)
        }
        let value: JSONValue = .object([
            "sessionId": .string("s"), "provider": .string("codex"),
            "usage": .object(["totalTokens": .number(10_000), "contextUsed": .number(60_000), "contextWindow": .number(100_000)]),
            "turnUsage": .array([
                turn("t1", total: 1_000, context: 20_000),
                turn("t2", total: 3_000, context: 30_000),
                turn("t3", total: 2_000, context: 40_000),
                turn("t4", running: true, total: 3_000, context: 50_000)
            ])
        ])
        guard let session = GatewaySession(value) else { throw CheckError.failed("session did not decode") }
        let forecast = UsageForecast(session: session)
        try check(forecast.currentTurnRunning && forecast.currentTurnTokens == 3_000, "the running turn reports its use so far")
        try check(forecast.typicalTurnTokens == 2_000, "the estimate is the median of completed turns")
        try check(forecast.progress == 1.5, "progress compares the running turn to the typical one")
        try check(forecast.turnsUntilContextFull == 4, "context left / median growth per turn")

        let fresh: JSONValue = .object(["sessionId": .string("n"), "provider": .string("grok"),
                                        "turnUsage": .array([turn("only", total: 500, context: nil), turn("now", running: true, total: nil, context: nil)])])
        guard let newSession = GatewaySession(fresh) else { throw CheckError.failed("session did not decode") }
        let early = UsageForecast(session: newSession)
        try check(early.typicalTurnTokens == nil, "one turn is not a pattern")
        try check(early.currentTurnRunning && early.currentTurnTokens == nil, "Grok's running turn is settled at its end")

        let work = WorkUsage(sessions: [session, newSession])
        try check(work.totalTokens == 10_000 && work.currentTurnTokens == 3_000 && work.runningSessions == 2,
                  "a Frontdoor's work adds up its sessions")
        try check(work.settlingSessions == 1 && work.currentTurnText == "이번 턴 3.0K"
                  && work.currentTurnHelp == "토큰이 턴 끝에 확정되는 세션 1개는 합계에서 빠져 있습니다.",
                  "a mixed sum names the sessions it leaves out: \(work.currentTurnHelp ?? "nil")")
        let settling = WorkUsage(sessions: [newSession])
        try check(settling.currentTurnText == "이번 턴 집계 중", "a running Grok turn reads 집계 중, never nothing")
        try check(WorkUsage(sessions: []).currentTurnText == nil, "nothing running, no pill")
    }

    private static func dashboardPanelsFoldByWidthAndOpenOnDemand() throws {
        let wide = DashboardPanelLayout(width: 1_200, wantsSessions: true, wantsInspector: true)
        try check(wide.showsSessions && wide.showsInspector, "a wide window shows both side panels")
        let medium = DashboardPanelLayout(width: 800, wantsSessions: true, wantsInspector: true)
        try check(medium.showsSessions && !medium.showsInspector, "the inspector folds first")
        let narrow = DashboardPanelLayout(width: 560, wantsSessions: true, wantsInspector: true)
        try check(!narrow.showsSessions && !narrow.showsInspector, "a narrow window keeps only the sequence")
        let noList = DashboardPanelLayout(width: 700, wantsSessions: false, wantsInspector: true)
        try check(noList.showsInspector, "without the session list the inspector has room")
        let forced = DashboardPanelLayout(width: 560, wantsSessions: true, wantsInspector: true, forceSessions: true)
        try check(forced.showsSessions, "a folded panel opens when the user asks")
        try check(wide.fitsBoth && !medium.fitsBoth, "fitsBoth tells when opening one panel folds the other")
        let forcedInspector = DashboardPanelLayout(width: 800, wantsSessions: true, wantsInspector: true, forceInspector: true)
        try check(forcedInspector.showsInspector && !forcedInspector.showsSessions, "a forced inspector takes the session list's place where both do not fit")
        let hidden = DashboardPanelLayout(width: 1_200, wantsSessions: false, wantsInspector: false)
        try check(!hidden.showsSessions && !hidden.showsInspector, "a hidden panel stays hidden however wide")
    }

    private static func sessionNamesFollowTheNamingPolicy() throws {
        func session(_ fields: [String: JSONValue]) throws -> GatewaySession {
            var object: [String: JSONValue] = ["sessionId": .string("local:codex:01a0db71-dd81"), "provider": .string("codex")]
            object.merge(fields) { _, new in new }
            guard let value = GatewaySession(.object(object)) else { throw CheckError.failed("session did not decode") }
            return value
        }
        let titled = try session(["title": .string("fix the build")])
        try check(titled.displayName == "fix the build", "a title names the session")
        let foldered = try session(["cwd": .string("/Users/me/dev/AgenLynk")])
        try check(foldered.displayName == "AgenLynk", "else its folder; the provider is the icon")
        let bare = try session([:])
        try check(bare.displayName == "새 세션" && !bare.displayName.contains("01a0"), "a raw id is never a name")
        // Tool-call text a local CLI parks in its title is not a name
        // (the same filter as a Frontdoor's designated name).
        let toolish = try session(["title": .string("custom_tool_call/exec"), "cwd": .string("/Users/me/dev/AgenLynk")])
        try check(toolish.displayName == "AgenLynk", "a tool-call title falls back to the folder: \(toolish.displayName)")
        let functionCall = try session(["title": .string("function_call")])
        try check(functionCall.displayName == "새 세션", "a function_call title without a folder is 새 세션")
        let eventPath = try session(["title": .string("hook/PreToolUse"), "cwd": .string("/")])
        try check(eventPath.displayName == "새 세션", "a /-joined event path is not a name")
        let sentence = try session(["title": .string("fix src/app.swift build")])
        try check(sentence.displayName == "fix src/app.swift build", "a prompt that mentions a path is still a name")
    }

    /// GET /api/hooks as sidecar/src/hooks/installer.js#hookStatus shapes it.
    private static func monitoringHookStatusDecodesPerCliState() throws {
        let json = """
        {"receiving":true,"enabled":true,"consentRequired":true,"targets":{
          "grok":{"agentPresent":true,"disabled":true,"installed":false,"partial":false,"file":"/g/hooks/agenlynk.json","events":[]},
          "codex":{"agentPresent":true,"disabled":false,"installed":true,"partial":false,"needsTrust":true,"untrustedEvents":["Stop"],"file":"/c/hooks.json","events":["Stop"]},
          "claude":{"agentPresent":true,"disabled":false,"installed":false,"partial":false,"error":"invalid JSON","file":"/a/settings.json","events":[]}
        },"errors":{"claude":"settings.json: invalid JSON; left unchanged"}}
        """
        let status = try MonitoringHookStatus.decode(Data(json.utf8))
        try check(status.receiving, "hook receiving flag must decode")
        try check(status.consentRequired, "a pending consent question must decode")
        try check(status.targets.map(\.provider) == ["claude", "codex", "grok"], "targets must list in a stable CLI order")
        try check(status.targets[1].needsTrust, "Codex pending trust must decode")
        try check(status.targets[2].disabled && !status.targets[2].installed, "an opted-out CLI must decode as disabled")
        try check(status.targets[0].error == "invalid JSON", "a config error must reach the settings row")
        try check(status.errors.count == 1, "install errors must decode")
        try check(status.lastReceivedAt.isEmpty, "a missing lastReceivedAt decodes as none received")
    }

    private static func monitoringHookStatusDecodesLastReceivedAndStateText() throws {
        let json = """
        {"receiving":true,"consentRequired":false,"lastReceivedAt":{"claude":"2026-08-07T00:00:00.000Z","codex":"not a date"},"targets":{
          "claude":{"agentPresent":true,"installed":true},
          "codex":{"agentPresent":true,"installed":true},
          "grok":{"agentPresent":true,"partial":true}
        }}
        """
        let status = try MonitoringHookStatus.decode(Data(json.utf8))
        try check(status.lastReceivedAt["claude"] != nil, "an ISO lastReceivedAt must decode")
        try check(status.lastReceivedAt["codex"] == nil, "an unparsable time is dropped, not fatal")
        let now = status.lastReceivedAt["claude"]!.addingTimeInterval(180)
        try check(status.stateText(for: status.targets[0], now: now) == "등록됨 · 마지막 수신 3분 전", "a received CLI shows how long ago")
        try check(status.stateText(for: status.targets[1], now: now) == "등록됨 · 아직 수신 없음", "a silent CLI says nothing arrived")
        try check(status.stateText(for: status.targets[2], now: now) == "일부만 등록됨", "partial registration reads as partial")
        let trust = MonitoringHookTarget(provider: "codex", .object(["agentPresent": .bool(true), "installed": .bool(true), "needsTrust": .bool(true)]))!
        try check(status.stateText(for: trust) == "승인 필요", "Codex trust wins over registered")
        let absent = MonitoringHookTarget(provider: "grok", .object([:]))!
        try check(status.stateText(for: absent) == "설치된 CLI 없음", "no CLI installed")
        let off = MonitoringHookTarget(provider: "grok", .object(["agentPresent": .bool(true), "disabled": .bool(true)]))!
        try check(status.stateText(for: off) == "꺼짐", "an opted-out CLI reads as off")
        let broken = MonitoringHookTarget(provider: "claude", .object(["agentPresent": .bool(true), "error": .string("bad")]))!
        try check(status.stateText(for: broken) == "설정 파일 오류", "a config error reads as such")
    }

    private static func historyEndpointsDecode() throws {
        let stats = try MonitorHistoryStats.decode(Data(#"{"available":true,"path":"/x/monitor.db","bytes":2048,"sessions":3,"events":40,"retentionDays":14}"#.utf8))
        try check(stats.available && stats.sessions == 3 && stats.events == 40 && stats.bytes == 2048, "history stats decode")
        try check(stats.retentionText == "14일" && !stats.diskHistoryOff, "retention reads in days")
        let off = try MonitorHistoryStats.decode(Data(#"{"available":false,"retentionDays":0}"#.utf8))
        try check(off.diskHistoryOff && off.retentionText == "보관 안 함", "retention 0 means no disk history")
        let cleared = try MonitorHistoryStats.decode(Data(#"{"deleted":5,"available":true,"sessions":1}"#.utf8))
        try check(cleared.deleted == 5 && cleared.retentionText == nil, "a clear response carries the deleted count")

        let page = try MonitorHistoryPage.decode(Data(#"{"sessions":[{"sessionId":"h1","provider":"claude","status":"closed","updatedAt":"2026-08-07T00:00:00.000Z"},{"nope":1}],"hasMore":true}"#.utf8))
        try check(page.sessions.map(\.sessionId) == ["h1"] && page.hasMore, "history pages decode and skip malformed records")

        let events = try SessionEventsPage.decode(Data(#"""
        {"sessionId":"s1","events":[
          {"id":"s1#b","key":"b","sessionId":"s1","sequence":2,"kind":"agent_message","ts":"2026-08-07T00:00:02.000Z"},
          {"id":"s1#a","key":"a","sessionId":"s1","sequence":1,"kind":"turn_start","ts":"2026-08-07T00:00:01.000Z"},
          {"id":"s2#c","key":"c","sessionId":"s2","sequence":1,"kind":"turn_start","ts":"2026-08-07T00:00:01.000Z"}
        ]}
        """#.utf8), sessionId: "s1")
        try check(events.events.compactMap(\.sequence) == [1, 2], "session events decode oldest first and only for the session")
        try check(EventTimeline.olderCursor(in: events.events) == nil, "sequence 1 loaded means nothing older")
        try check(EventTimeline.olderCursor(in: [events.events[1]]) == 2, "the cursor is the lowest loaded sequence")
    }

    private static func toolCallsGroupPerTurnAndRequestsStayVisible() throws {
        let t0 = "2026-08-07T00:00:0"
        let events = [
            try canonicalEvent("s1", 1, "turn_start", ts: "\(t0)1.000Z", turnId: "t1"),
            try canonicalEvent("s1", 2, "tool_call", ts: "\(t0)2.000Z", turnId: "t1", title: "Read: README.md", status: "completed"),
            try canonicalEvent("s1", 3, "tool_call", ts: "\(t0)3.000Z", turnId: "t1", title: "Bash: npm test -- --watch=false --reporter=dot", status: "running"),
            try canonicalEvent("s1", 4, "tool_call", ts: "\(t0)4.000Z", turnId: "t1", title: "Edit: a.swift", status: "failed"),
            try canonicalEvent("s1", 5, "permission_request", ts: "\(t0)5.000Z", turnId: "t1", status: "pending"),
            try canonicalEvent("s1", 6, "tool_call", ts: "\(t0)6.000Z", turnId: "t1", title: "Bash: ls", status: "completed"),
            try canonicalEvent("s1", 7, "tool_call", ts: "\(t0)7.000Z", turnId: "t2", title: "Bash: pwd", status: "completed"),
            try canonicalEvent("s1", 8, "tool_call", ts: "\(t0)8.000Z", turnId: "t2", title: "Bash: whoami", status: "completed"),
        ]
        let items = EventTimeline.group(events)
        try check(items.count == 5, "turn_start, group, permission, single call, next-turn group; got \(items.count)")
        guard case let .tools(first) = items[1] else { throw CheckError.failed("three calls in one turn must group") }
        try check(first.events.count == 3 && first.failedCount == 1, "the group counts its calls and failures")
        try check(first.representative.sequence == 3, "the running call represents the group")
        try check(first.summary() == "도구 3개 · 실행 중: Bash: npm test -- --watch=fa… · 실패 1", "group summary: \(first.summary())")
        guard case let .event(permission) = items[2] else { throw CheckError.failed("a permission request stays its own row") }
        try check(permission.headline == "권한 요청 대기", "a pending permission reads as waiting")
        guard case .event = items[3] else { throw CheckError.failed("a lone call between breaks stays single") }
        guard case let .tools(second) = items[4] else { throw CheckError.failed("a new turn starts a new group") }
        try check(second.representative.sequence == 8 && second.summary().hasPrefix("도구 2개 · 마지막: Bash: whoami"), "without a running call the latest represents")

        let interleaved = EventTimeline.group([events[1], try canonicalEvent("s2", 1, "tool_call", turnId: "t1"), events[2]])
        try check(interleaved.count == 3, "another session's event ends a run")

        let collapsed = EventTimeline.rows(items, expanded: [])
        try check(collapsed.count == 5 && collapsed[1].coveredEventIds.count == 3, "a collapsed group covers its calls")
        let expanded = EventTimeline.rows(items, expanded: [first.id])
        try check(expanded.count == 8, "an expanded group lists its calls under the header")
        try check(expanded[1].coveredEventIds.isEmpty && expanded[2].parentGroupId == first.id, "expanded calls carry their own rows")
        try check(EventTimeline.trailingToolGroup(events)?.id == second.id, "the trailing run is the newest group")
        try check(first.id == "tools:s1#tool_call:2", "a group's id is its first call's, stable as the run grows")

        // Older-load anchoring: an expanded header covers nothing, so the
        // first call under it anchors; a collapsed group anchors on its newest.
        let groupFirst = EventTimeline.rows(Array(items.dropFirst()), expanded: [first.id])
        try check(EventTimeline.anchorEventId(in: groupFirst) == first.events[0].id, "an expanded header anchors on its first call")
        let groupCollapsed = EventTimeline.rows(Array(items.dropFirst()), expanded: [])
        try check(EventTimeline.anchorEventId(in: groupCollapsed) == first.events.last?.id, "a collapsed group anchors on its newest call")
        try check(EventTimeline.rowId(showing: first.events[0].id, in: groupCollapsed) == first.id, "a call hidden in a collapsed group is found through it")

        // A call a hook reported live represents the run over a transcript-only one.
        func sourced(_ seq: Int, _ sources: [String]) throws -> MonitorEvent {
            MonitorEvent(.object(["id": .string("h#\(seq)"), "sessionId": .string("h"), "kind": .string("tool_call"), "turnId": .string("t"),
                                  "sequence": .number(Double(seq)), "status": .string("running"), "title": .string("call \(seq)"),
                                  "sources": .array(sources.map(JSONValue.string))]))!
        }
        let live = ToolCallGroup(events: [try sourced(1, ["hook"]), try sourced(2, ["transcript"])])
        try check(live.representative.id == "h#1" && live.isHookObserved, "the hook-seen running call leads the group")
    }

    private static func permissionOutcomesAndKoreanLabelsRead() throws {
        func permission(_ status: String, outcome: String?) -> MonitorEvent {
            var value: [String: JSONValue] = [
                "id": .string("s#p"), "sessionId": .string("s"), "kind": .string("permission_request"), "status": .string(status)
            ]
            if let outcome { value["detail"] = .object(["outcome": .string(outcome)]) }
            return MonitorEvent(.object(value))!
        }
        try check(permission("pending", outcome: nil).headline == "권한 요청 대기", "pending permission")
        try check(permission("completed", outcome: "approved").headline == "승인됨", "approved permission")
        try check(permission("completed", outcome: "denied").headline == "거부됨", "denied by outcome wins over status")
        try check(permission("cancelled", outcome: "cancelled").headline == "취소됨", "cancelled permission")
        try check(permission("failed", outcome: nil).headline == "거부됨", "a failed permission without outcome reads as denied")
        for (kind, label) in [("turn_start", "턴 시작"), ("turn_end", "턴 종료"), ("agent_thought", "생각"), ("subagent", "서브에이전트"),
                              ("plan", "계획"), ("compaction", "컨텍스트 압축"), ("error", "오류"), ("session_start", "세션 시작"),
                              ("session_end", "세션 종료"), ("input_request", "입력 요청"), ("permission_request", "권한 요청"),
                              ("user_message", "사용자 입력"), ("agent_message", "응답"), ("tool_call", "도구 호출"), ("new_kind", "알 수 없는 이벤트")] {
            try check(eventKindLabel(kind) == label, "\(kind) must read as \(label)")
        }
        for (status, label) in [("running", "실행 중"), ("waiting_permission", "권한 대기"), ("waiting_input", "입력 대기"), ("idle", "대기"),
                                ("closed", "종료"), ("error", "오류"), ("disconnected", "연결 끊김"), ("unavailable", "사용 불가"),
                                ("cancelling", "취소 중"), ("restoring", "복원 중"), ("ready", "대기"), ("end_turn", "대기"),
                                ("completed", "대기"), ("mystery", "알 수 없음")] {
            try check(sessionStatusLabel(status) == label, "\(status) must read as \(label)")
        }
        try check(recordStatusLabel("completed") == "완료" && recordStatusLabel("pending") == "대기 중", "a finished record is done, not resting")
        for (status, label) in [("pending", "시작 전"), ("running", "실행 중"), ("completed", "완료"), ("failed", "실패"), ("cancelled", "취소됨")] {
            try check(eventStatusLabel(status) == label, "event status \(status) must read as \(label)")
        }
        try check(eventStatusLabel(nil) == nil, "no status, no label")
        // A request's outcome wins over the generic status word.
        let denied = permission("completed", outcome: "denied")
        try check(denied.stateLabel == "거부됨", "a denied permission never reads 완료: \(denied.stateLabel ?? "nil")")
        let tool = MonitorEvent(.object(["id": .string("s#t2"), "sessionId": .string("s"), "kind": .string("tool_call"), "status": .string("cancelled")]))!
        try check(tool.stateLabel == "취소됨", "a cancelled tool call reads 취소됨")
        // Activity headlines (docs/ux-policy.md §3).
        try check(sessionActivityHeadline(status: "running", isActive: true, latestKind: "agent_thought") == "생각 중", "thinking")
        try check(sessionActivityHeadline(status: "running", isActive: true, latestKind: "agent_message") == "응답 생성 중", "responding")
        try check(sessionActivityHeadline(status: "running", isActive: true, latestKind: "tool_call") == "실행 중", "running a tool")
        try check(sessionActivityHeadline(status: "waiting_permission", isActive: true, latestKind: nil) == "권한 대기 중", "permission wait")
        try check(sessionActivityHeadline(status: "waiting_input", isActive: true, latestKind: nil) == "입력 대기 중", "input wait")
        try check(sessionActivityHeadline(status: "end_turn", isActive: false, latestKind: "turn_end") == "대기 · 다음 입력을 기다림", "resting")
        try check(sessionActivityHeadline(status: "closed", isActive: false, latestKind: nil) == "종료됨", "closed")
        try check(sessionActivityHeadline(status: "cancelling", isActive: true, latestKind: "tool_call") == "취소 중", "cancelling never reads 실행 중")
        try check(sessionActivityHeadline(status: "mystery", isActive: false, latestKind: nil) == "알 수 없음", "an unlisted status reads 알 수 없음")
        try check(withObjectParticle("세션 목록") == "세션 목록을" && withObjectParticle("인스펙터") == "인스펙터를", "object particles follow the last syllable")
        try check(providerDisplayLabel("") == "알 수 없는 CLI" && providerDisplayLabel("codex") == "Codex", "an unknown provider never reads Agent")
        let unknownAlert = SessionAlert(.object(["code": .string("some_new_code")]))!
        try check(unknownAlert.badge == "경고" && unknownAlert.tooltip == "자세한 설명이 없는 경고입니다.", "an unknown alert code is never shown raw")
        let long = MonitorEvent(.object(["id": .string("s#t"), "sessionId": .string("s"), "kind": .string("tool_call"),
                                         "title": .string("exec_command: wc -l README.md docs/a.md docs/b.md")]))!
        try check(long.compactToolTitle(limit: 28) == "exec_command: wc -l README.m…", "long titles cut to the limit: \(long.compactToolTitle(limit: 28))")
    }

    private static func sessionCapabilitiesDistinguishBlindFromIdle() throws {
        func session(source: String, capabilities: [String]?) -> GatewaySession {
            var value: [String: JSONValue] = ["sessionId": .string("s"), "provider": .string("claude"), "source": .string(source)]
            if let capabilities { value["capabilities"] = .array(capabilities.map(JSONValue.string)) }
            return GatewaySession(.object(value))!
        }
        let hooked = session(source: "local", capabilities: ["status", "timeline", "permission", "live"])
        try check(hooked.isLiveObserved && !hooked.cannotObservePermission, "a hooked local session sees permissions live")
        let transcript = session(source: "local", capabilities: ["status", "timeline", "tools"])
        try check(!transcript.isLiveObserved && transcript.cannotObservePermission, "without hooks permissions are invisible")
        try check(!session(source: "local", capabilities: nil).cannotObservePermission, "no capabilities (older sidecar) flags nothing")
        try check(!session(source: "gateway", capabilities: ["status"]).cannotObservePermission, "a Gateway session is never flagged")
        let closed = GatewaySession(.object(["sessionId": .string("c"), "provider": .string("claude"), "status": .string("closed"),
                                             "capabilities": .array([.string("live"), .string("status")])]))!
        try check(!closed.isLiveObserved && !closed.canShowTimeline, "a closed session is not live; no timeline capability means none")

        func member(_ id: String, role: String, status: String) -> GatewaySession {
            GatewaySession(.object(["sessionId": .string(id), "provider": .string("codex"), "role": .string(role),
                                    "status": .string(status), "openerInstanceId": .string("fd")]))!
        }
        let waiting = FrontdoorSession.make(sessions: [member("root", role: "frontdoor", status: "running"),
                                                       member("w1", role: "worker", status: "waiting_permission"),
                                                       member("w2", role: "worker", status: "running")])[0]
        try check(waiting.statusText == "권한 대기 1" && waiting.statusKey == "waiting_permission", "a waiting member shows on the Frontdoor")
        try check(waiting.runningCount == 2 && waiting.countsLine == "Worker 2 · 실행 중 2", "waiting is not counted as running: \(waiting.countsLine)")
        try check(waiting.preferredSession?.sessionId == "w1", "selecting the Frontdoor lands on the waiting worker")
        let over = FrontdoorSession.make(sessions: [member("root", role: "frontdoor", status: "closed")])[0]
        try check(over.statusText == "종료" && over.isClosed, "all members closed reads 종료")
        let both = FrontdoorSession.make(sessions: [member("root", role: "frontdoor", status: "waiting_input"),
                                                    member("w1", role: "worker", status: "waiting_permission"),
                                                    member("w2", role: "worker", status: "waiting_input")])[0]
        try check(both.statusText == "권한 대기 1 · 입력 대기 2", "both waits are stated: \(both.statusText)")
        let resting = FrontdoorSession.make(sessions: [member("root", role: "frontdoor", status: "idle")])[0]
        try check(resting.statusText == "대기", "a resting Frontdoor reads 대기, apart from 종료")

        // "실시간" and the hook note are for live sessions only.
        try check(hooked.showsRealtimeBadge(inHistory: false) && !hooked.showsRealtimeBadge(inHistory: true),
                  "a history session never reads 실시간")
        try check(transcript.showsPermissionBlindNote(inHistory: false) && !transcript.showsPermissionBlindNote(inHistory: true),
                  "the hook note explains a live session only")
        try check(isHistorySession("gone", liveSessionIds: ["live"], openedHistoryId: nil), "a session out of the snapshot is history")
        try check(isHistorySession("live", liveSessionIds: ["live"], openedHistoryId: "live"), "the opened history session is history")
        try check(!isHistorySession("live", liveSessionIds: ["live"], openedHistoryId: nil), "a snapshot session is live")
    }

    private static func agentCatalogDecodesInstallAndEnabledState() throws {
        let data = Data(#"""
        {
          "registryVersion":"1.0.0","source":"cache","stale":false,
          "agents":[
            {"registryId":"gemini","providerId":"gemini","name":"Gemini CLI","version":"2.0","description":"agent","website":"https://example.test","distribution":"npx","compatible":true,"installed":true,"enabled":false,"installSupported":true,"installHint":"install"},
            {"registryId":"manual","providerId":"manual","name":"Manual","version":"1.0","description":"binary","distribution":"binary","compatible":true,"installed":false,"enabled":false,"installSupported":false,"installHint":"manual"}
          ]
        }
        """#.utf8)
        let response = try ACPAgentCatalogSnapshot.decode(data)
        try check(response.registryVersion == "1.0.0", "registry metadata decode failed")
        try check(response.agents.count == 2, "agent catalog decode failed")
        try check(response.agents[0].installed && !response.agents[0].enabled, "installed and enabled must be independent")
        try check(!response.agents[1].installSupported, "manual binary install state decode failed")
    }

    private static func installedFrontdoorsDecodePrimaryInstalledAndNullEmpty() throws {
        let populated = try InstalledFrontdoors.decode(Data(#"""
        {"primary":"codex","installed":["codex","claude"]}
        """#.utf8))
        try check(populated.primary == "codex", "installed frontdoors primary decode failed")
        try check(populated.installed == ["codex", "claude"], "installed frontdoors list decode failed")

        let empty = try InstalledFrontdoors.decode(Data(#"""
        {"primary":null,"installed":[]}
        """#.utf8))
        try check(empty.primary == nil, "null primary must decode to nil")
        try check(empty.installed.isEmpty, "empty installed list decode failed")
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

    private static func gatewayConfigRepresentsAllKnownSettingIds() throws {
        // Mirrors GATEWAY_SETTING_DEFINITIONS in src/gateway-settings.js. When a
        // setting is added there, add it here too — this is what proves the
        // Swift decode path accepts the whole catalogue.
        let lifecycleIds = ["gcIntervalMs", "idleUnloadMs", "orphanGraceMs", "resultRetentionMs", "inboxRetentionMs", "sessionRetentionMs"]
        let resourceLimitIds = ["maxEvents", "maxTextBytes", "maxInlineResultBytes", "maxArtifactBytes", "maxArtifactTotalBytes", "artifactSessionLimit", "maxTerminalsPerSession", "maxPendingRequestsPerSession", "maxFrameBytes"]
        let workerIds = ["workerThoughtStream", "workerSubagentTranscript"]
        let monitorIds = ["localScannerEnabled", "localScanIntervalMs", "localDiscoveryIntervalMs", "localTranscriptWindowMs", "localTranscriptRecordLimit"]
        let agentUpdateIds = ["agentAutoUpdate", "agentUpdateNotifications", "agentUpdateIntervalMs"]
        let allIds = lifecycleIds + resourceLimitIds + workerIds + monitorIds + agentUpdateIds
        try check(allIds.count == 25, "fixture must cover exactly the 25 known Gateway setting ids")

        func option(_ id: String, group: String, type: String) -> [String: JSONValue] {
            [
                "id": .string(id), "group": .string(group), "type": .string(type),
                "label": .string(id), "description": .string(""),
                "defaultValue": type == "boolean" ? .bool(true) : .number(0),
                "currentValue": type == "boolean" ? .bool(true) : .number(0),
                "source": .string("default"), "environment": .string("ACP_GATEWAY_\(id.uppercased())"),
                "editable": .bool(true), "requiresRestart": .bool(true), "pending": .bool(false)
            ]
        }
        let options: [JSONValue] = lifecycleIds.map { .object(option($0, group: "lifecycle", type: "number")) }
            + resourceLimitIds.map { .object(option($0, group: "resourceLimits", type: "number")) }
            + workerIds.map { .object(option($0, group: "workers", type: "boolean")) }
            + monitorIds.map { .object(option($0, group: "monitor", type: $0 == "localScannerEnabled" ? "boolean" : "number")) }
            + agentUpdateIds.map { .object(option($0, group: "agentUpdates", type: $0 == "agentUpdateIntervalMs" ? "number" : "boolean")) }
        let root = JSONValue.object(["ok": .bool(true), "pendingRestart": .bool(false), "pendingLiveApply": .bool(false), "options": .array(options)])
        let data = try JSONSerialization.data(withJSONObject: root.foundationValue)
        let snapshot = try GatewayConfigSnapshot.decode(data)
        try check(snapshot.options.count == 25, "all 25 Gateway setting ids must decode")
        try check(Set(snapshot.options.map(\.id)) == Set(allIds), "decoded ids must match every known Gateway setting id")
    }

    /// The confirmation prompt is only trustworthy if a failed or empty
    /// preview cannot be mistaken for "nothing will be deleted".
    private static func gatewayConfigDecodesBothLanguagesAndFallsBackToEnglish() throws {
        let data = Data(#"""
        {
          "ok":true,
          "pendingRestart":false,
          "pendingLiveApply":false,
          "options":[
            {"id":"sessionRetentionMs","group":"lifecycle","type":"number","label":"Session retention","labelKo":"세션 보존 기간","description":"How long completed session records are retained.","descriptionKo":"완료된 세션 기록을 보관하는 기간입니다.","unit":"ms","displayUnit":"days","minimum":0,"defaultValue":604800000,"currentValue":604800000,"configuredValue":604800000,"source":"default","environment":"ACP_GATEWAY_SESSION_RETENTION_MS","editable":true,"requiresRestart":true,"pending":false},
            {"id":"maxEvents","group":"resourceLimits","type":"number","label":"Events per session","labelKo":"세션당 이벤트 수","description":"limit","descriptionKo":"제한","unit":"count","displayUnit":null,"minimum":1,"defaultValue":200,"currentValue":200,"configuredValue":200,"source":"default","environment":"ACP_GATEWAY_MAX_EVENTS","editable":true,"requiresRestart":true,"pending":false},
            {"id":"futureSetting","group":"lifecycle","type":"number","label":"Future setting","description":"only English","unit":"ms","displayUnit":"fortnights","minimum":0,"defaultValue":1,"currentValue":1,"configuredValue":1,"source":"default","environment":"ACP_GATEWAY_FUTURE","editable":true,"requiresRestart":true,"pending":false}
          ]
        }
        """#.utf8)
        let options = try GatewayConfigSnapshot.decode(data).options
        try check(options[0].labelKo == "세션 보존 기간", "Korean label decode failed")
        try check(options[0].descriptionKo == "완료된 세션 기록을 보관하는 기간입니다.", "Korean description decode failed")
        try check(options[0].label == "Session retention", "English label must survive alongside Korean")
        try check(options[0].displayUnit == .days, "display unit decode failed")
        try check(options[1].displayUnit == nil, "a non-duration setting must have no display unit")
        // An older Gateway (or a setting added before its translation) must
        // degrade to English instead of showing an empty row.
        try check(options[2].labelKo == "Future setting", "missing Korean label must fall back to English")
        try check(options[2].descriptionKo == "only English", "missing Korean description must fall back to English")
        // An unknown unit is presentation metadata this build cannot honour;
        // milliseconds are always a correct way to show the value.
        try check(options[2].displayUnit == nil, "unknown display unit must not be guessed at")
    }

    private static func gatewayDisplayUnitsRoundTripExactlyAndFallBackToMilliseconds() throws {
        func option(_ id: String, unit: String, displayUnit: String?, minimum: Int) throws -> GatewayConfigOption {
            var fields: [String: JSONValue] = [
                "id": .string(id), "group": .string("lifecycle"), "type": .string("number"),
                "label": .string(id), "description": .string(""), "unit": .string(unit),
                "minimum": .number(Double(minimum)), "defaultValue": .number(0), "currentValue": .number(0),
                "source": .string("default"), "environment": .string("ACP_TEST"),
                "editable": .bool(true), "requiresRestart": .bool(true), "pending": .bool(false)
            ]
            if let displayUnit { fields["displayUnit"] = .string(displayUnit) }
            guard let decoded = GatewayConfigOption(.object(fields)) else {
                throw MonitorDecodeError.invalidMessage
            }
            return decoded
        }

        let retention = try option("sessionRetentionMs", unit: "ms", displayUnit: "days", minimum: 0)
        let week = retention.valueScale(for: 604_800_000)
        try check(week.display(604_800_000) == 7, "7 days must display as 7")
        try check(week.stored(7) == 604_800_000, "7 days must store back as 604800000 ms")
        try check(week.suffix == "일", "scaled rows must label the display unit, not milliseconds")

        let scan = try option("localScanIntervalMs", unit: "ms", displayUnit: "seconds", minimum: 250)
        let second = scan.valueScale(for: 1_000)
        try check(second.display(1_000) == 1 && second.stored(1) == 1_000, "1s ↔ 1000ms round-trip failed")

        // Values that do not divide evenly are shown exactly as stored rather
        // than rounded into a different setting.
        let uneven = retention.valueScale(for: 90_000_000)
        try check(!uneven.isScaled && uneven.suffix == "ms", "an uneven value must fall back to milliseconds")
        try check(uneven.display(90_000_000) == 90_000_000, "millisecond fallback must not scale the value")
        try check(uneven.stored(90_000_000) == 90_000_000, "millisecond fallback must round-trip untouched")
        try check(!scan.valueScale(for: 250).isScaled, "a sub-unit minimum must fall back to milliseconds")

        // Zero divides evenly, and "0 minutes" is exactly what disabling means.
        try check(retention.valueScale(for: 0).display(0) == 0, "zero must stay zero in display units")

        let counted = try option("maxEvents", unit: "count", displayUnit: nil, minimum: 1)
        let plain = counted.valueScale(for: 200)
        try check(!plain.isScaled && plain.suffix == "count", "non-duration settings keep their own unit")
        try check(plain.display(200) == 200 && plain.stored(200) == 200, "non-duration settings must not be scaled")

        // A typed-in absurd number must saturate, not trap on overflow.
        try check(week.stored(Int.max) == Int.max, "overflowing display values must saturate")
    }

    private static func retentionPreviewDecodesCountsAndSummarisesOnlyNonZeroOnes() throws {
        let data = Data(#"{"ok":true,"sessions":3,"tasks":0,"inbox":2,"artifacts":11}"#.utf8)
        let preview = try RetentionPreview.decode(data)
        try check(preview.sessions == 3 && preview.inbox == 2 && preview.artifacts == 11, "counts must decode")
        try check(!preview.isEmpty, "a preview with counts is not empty")
        try check(preview.summary.contains("세션 3개"), "the summary must name sessions")
        try check(!preview.summary.contains("태스크"), "a zero count must be left out of the summary")

        let empty = try RetentionPreview.decode(Data(#"{"ok":true,"sessions":0,"tasks":0,"inbox":0,"artifacts":0}"#.utf8))
        try check(empty.isEmpty, "an all-zero preview means the save destroys nothing")
        try check(empty.summary.isEmpty, "an all-zero preview has no summary")

        // Missing fields decode as zero rather than throwing, but a malformed
        // body must not silently become an empty preview.
        try check(RetentionPreview(.string("nope")) == nil, "a non-object body must not decode")
    }

    /// The updater screen must read the library's own envelopes, including the
    /// failure shape, so the app and the CLI can never disagree.
    private static func runtimeInspectionAndOperationEnvelopesDecode() throws {
        let inspectJSON = #"""
        {"ok":true,"op":"inspect","runtimeRoot":"/Users/x/.acp-gateway/runtime",
         "current":{"runtimeRoot":"/Users/x/.acp-gateway/runtime/versions/1.3.1-aaa","gatewayVersion":"1.3.1","gatewayBuildId":"aaa"},
         "previous":{"runtimeRoot":"/Users/x/.acp-gateway/runtime/versions/1.3.1-bbb","gatewayVersion":"1.3.1","gatewayBuildId":"bbb"},
         "versions":[
           {"versionId":"1.3.1-aaa","runtimeRoot":"/Users/x/.acp-gateway/runtime/versions/1.3.1-aaa","isCurrent":true,"isPrevious":false,"gatewayVersion":"1.3.1","gatewayBuildId":"aaa","gatewayApiVersion":1,"apiCompatible":true,"nodeVersion":"22.23.2"},
           {"versionId":"1.3.1-bbb","runtimeRoot":"/Users/x/.acp-gateway/runtime/versions/1.3.1-bbb","isCurrent":false,"isPrevious":true,"gatewayVersion":"1.3.1","gatewayBuildId":"bbb","gatewayApiVersion":2,"apiCompatible":false,"nodeVersion":"22.14.0"},
           {"versionId":"broken","runtimeRoot":"/Users/x/.acp-gateway/runtime/versions/broken","isCurrent":false,"isPrevious":false,"manifestError":"missing manifest"}
         ]}
        """#
        let inspection = try RuntimeInspection.decode(Data(inspectJSON.utf8))
        try check(inspection.currentVersionId == "1.3.1-aaa", "the current pointer resolves to a version id")
        try check(inspection.current?.nodeVersion == "22.23.2", "the current runtime reports its Node version")
        try check(inspection.canRollback, "a recorded previous target enables rollback")
        try check(inspection.versions.count == 3, "every installed version decodes, including a broken one")
        try check(inspection.versions[1].apiCompatible == false, "an incompatible API version is flagged")
        try check(inspection.versions[2].manifestError == "missing manifest", "an unreadable manifest is reported, not dropped")

        let activated = try RuntimeOperationResult.decode(Data(#"{"ok":true,"op":"activate","activated":{"versionId":"1.3.1-aaa"}}"#.utf8))
        try check(activated.ok && activated.versionId == "1.3.1-aaa", "activation reports the version it switched to")

        // An expected updater refusal is a decoded result, not a thrown error.
        let blocked = try RuntimeOperationResult.decode(Data(#"{"ok":false,"op":"activate","error":{"code":"ACTIVATION_BLOCKED","message":"activation deferred: active work is in progress","blockers":["진행 중 세션 1개"]}}"#.utf8))
        try check(!blocked.ok && blocked.errorCode == "ACTIVATION_BLOCKED", "a blocked activation keeps the library's stable code")
    }

    private static func sessionConfigDecodesSelectBooleanAndFlattensNestedChoices() throws {
        let data = Data(#"""
        {
          "ok": true,
          "sessionId": "s1",
          "configOptions": [
            {
              "type": "select", "id": "model", "name": "Model", "category": "model", "currentValue": "mock-pro",
              "options": [
                { "value": "mock-default", "name": "Mock Default" },
                {
                  "name": "Preview",
                  "options": [
                    { "value": "mock-pro", "name": "Mock Pro" },
                    { "value": "mock-ultra", "name": "Mock Ultra" }
                  ]
                }
              ]
            },
            { "type": "boolean", "id": "auto_compact", "name": "Auto compact", "currentValue": false }
          ]
        }
        """#.utf8)
        let snapshot = try SessionConfigSnapshot.decode(data)
        try check(snapshot.sessionId == "s1", "session config sessionId decode failed")
        try check(snapshot.unavailableReason == nil, "an available snapshot must not carry an unavailable reason")
        try check(snapshot.options.count == 2, "both select and boolean options should decode")

        guard case let .select(choices)? = snapshot.options.first(where: { $0.id == "model" })?.kind else {
            throw CheckError.failed("select option should decode as .select")
        }
        try check(choices.count == 3, "one level of nested choice groups must flatten to leaf values")
        try check(choices.map(\.value) == ["mock-default", "mock-pro", "mock-ultra"], "flattened choices must preserve backend order")
        try check(choices.first { $0.value == "mock-pro" }?.groupName == "Preview", "a flattened leaf should keep its nested group name")
        try check(choices.first { $0.value == "mock-default" }?.groupName == nil, "a top-level leaf should have no group name")

        guard case .boolean? = snapshot.options.first(where: { $0.id == "auto_compact" })?.kind else {
            throw CheckError.failed("boolean option should decode as .boolean")
        }
        try check(snapshot.options.first(where: { $0.id == "auto_compact" })?.currentValue.boolValue == false, "boolean currentValue decode failed")
    }

    private static func sessionConfigPreservesUnknownTypeInsteadOfDropping() throws {
        let data = Data(#"""
        {
          "ok": true, "sessionId": "s1",
          "configOptions": [
            { "type": "multi_select", "id": "tags", "name": "Tags", "currentValue": null }
          ]
        }
        """#.utf8)
        let snapshot = try SessionConfigSnapshot.decode(data)
        try check(snapshot.options.count == 1, "an option with an unrecognized type must still decode, not be dropped")
        guard case let .unknown(type)? = snapshot.options.first?.kind else {
            throw CheckError.failed("unrecognized config option type should decode as .unknown")
        }
        try check(type == "multi_select", "the unknown option should retain its raw type name for a disabled row label")
    }

    private static func sessionConfigDecodesUnavailableSnapshot() throws {
        let data = Data(#"""
        {
          "ok": true, "sessionId": "s1", "configOptions": [],
          "unavailableReason": "Worker 연결이 끊긴 세션입니다. 세션을 resume한 뒤 설정을 다시 불러오세요."
        }
        """#.utf8)
        let snapshot = try SessionConfigSnapshot.decode(data)
        try check(snapshot.options.isEmpty, "a disconnected session should report no config options")
        try check(snapshot.unavailableReason != nil, "a disconnected session should surface an unavailable reason")
    }

    /// A canonical v2 event as the sidecar sends it. `key` defaults to one
    /// derived from kind+sequence so fixtures only state what a check reads.
    private static func canonicalEvent(
        _ sessionId: String,
        _ sequence: Int,
        _ kind: String,
        ts: String = "2026-08-07T00:00:00.000Z",
        key: String? = nil,
        turnId: String? = nil,
        title: String? = nil,
        body: String? = nil,
        status: String? = nil
    ) throws -> MonitorEvent {
        let key = key ?? "\(kind):\(sequence)"
        var value: [String: JSONValue] = [
            "id": .string("\(sessionId)#\(key)"), "key": .string(key),
            "sessionId": .string(sessionId), "sequence": .number(Double(sequence)),
            "kind": .string(kind), "ts": .string(ts), "sources": .array([.string("gateway")])
        ]
        if let turnId { value["turnId"] = .string(turnId) }
        if let title { value["title"] = .string(title) }
        if let body { value["body"] = .string(body) }
        if let status { value["status"] = .string(status) }
        guard let event = MonitorEvent(.object(value)) else {
            throw CheckError.failed("canonical event fixture did not decode")
        }
        return event
    }

    /// v2 events are display-ready: title/body come straight from the wire,
    /// the id is the stable `<sessionId>#<key>`, and an event that names
    /// neither id nor key is rejected rather than given a random identity.
    private static func canonicalEventsDecodeTitleBodyStatusAndStableIds() throws {
        let tool = try canonicalEvent("s1", 3, "tool_call", key: "tool:call-1", title: "Bash: ls", body: "a\nb", status: "running")
        try check(tool.id == "s1#tool:call-1" && tool.key == "tool:call-1", "the wire id is kept")
        try check(tool.summary == "Bash: ls", "the summary is the sidecar's title")
        try check(tool.isInFlight && !tool.isFailed, "running is in flight")
        try check(tool.kindLabel == "도구 호출", "kind labels read as Korean words")
        try check(tool.headline == "Bash: ls", "a tool call leads with its compact header")

        let message = try canonicalEvent("s1", 4, "agent_message", body: "첫 줄\n둘째 줄")
        try check(message.summary == "첫 줄 둘째 줄", "without a title the summary is the body's head on one line")
        try check(message.kindLabel == "응답", "agent messages read as a response")

        let bare = try canonicalEvent("s1", 5, "turn_end", status: "failed")
        try check(bare.title == nil && bare.body == nil, "missing title/body stay nil")
        try check(bare.summary == "턴 종료" && bare.isFailed, "a bare event falls back to its kind")

        let keyOnly = MonitorEvent(.object([
            "sessionId": .string("s1"), "key": .string("turn:t1"), "kind": .string("turn_start"),
            "title": .string("   ")
        ]))
        try check(keyOnly?.id == "s1#turn:t1", "a missing id is derived from the key, the contract's own rule")
        try check(keyOnly?.title == nil, "a blank title is no title")
        try check(keyOnly?.sequence == nil && keyOnly?.status == nil && keyOnly?.detail.isEmpty == true,
                  "missing optional fields decode as nil/empty")

        let anonymous = MonitorEvent(.object([
            "sessionId": .string("s1"), "sequence": .number(1), "kind": .string("turn_start")
        ]))
        try check(anonymous == nil, "an event without id or key has no stable identity and must be rejected")
        let legacy = MonitorEvent(.object([
            "sessionId": .string("s1"), "sequence": .number(1), "type": .string("agent_message_chunk"), "text": .string("x")
        ]))
        try check(legacy == nil, "a v1 raw event (type/text) is not a canonical event")
    }

    /// The v2 `events` frame rule: same id replaces in place, a new id is
    /// inserted, and the bucket stays ordered by ts then sequence.
    /// `==` compares identity and display fields, never the raw payload; the
    /// in-place upsert reports whether anything visible changed.
    private static func eventEqualityIgnoresRawPayloadAndUpsertReportsChange() throws {
        let base: [String: JSONValue] = [
            "id": .string("s1#tool:1"), "key": .string("tool:1"), "sessionId": .string("s1"),
            "sequence": .number(1), "kind": .string("tool_call"), "ts": .string("2026-08-07T00:00:00.000Z"),
            "title": .string("Bash: ls"), "status": .string("running"), "sources": .array([.string("hook")])
        ]
        var noisy = base
        noisy["rawProviderBlob"] = .string(String(repeating: "x", count: 10_000))
        guard let plain = MonitorEvent(.object(base)), let withBlob = MonitorEvent(.object(noisy)) else {
            throw CheckError.failed("equality fixtures did not decode")
        }
        try check(plain == withBlob, "events differing only in raw payload compare equal")
        var finished = base
        finished["status"] = .string("completed")
        guard let done = MonitorEvent(.object(finished)) else { throw CheckError.failed("fixture did not decode") }
        try check(plain != done, "a status change is a change")

        var bucket = [plain]
        try check(!upsertMonitorEvents([withBlob], into: &bucket, limit: 10), "a payload-only change reports nothing")
        try check(upsertMonitorEvents([done], into: &bucket, limit: 10), "a visible change is reported")
        try check(bucket.count == 1 && bucket[0].status == "completed", "the event is replaced in place")
        try check(!upsertMonitorEvents([], into: &bucket, limit: 10), "an empty frame reports nothing")
    }

    private static func recentKeysKeepTheOpenOneAndTheNewestFew() throws {
        var recent = RecentKeys(capacity: 2)
        try check(recent.touch("a", pinned: "a").isEmpty, "the first key stays")
        try check(recent.touch("b", pinned: "b").isEmpty && recent.touch("c", pinned: "c").isEmpty, "capacity besides the pinned key")
        try check(recent.touch("d", pinned: "d") == ["a"], "the least recently used key drops first")
        try check(recent.touch("b", pinned: "b").isEmpty && recent.keys == ["c", "d", "b"], "touching moves a key to newest")
        try check(recent.touch("e", pinned: "c") == ["d"], "the pinned (open) key never drops, however old")
        try check(recent.keys == ["c", "b", "e"], "the open key plus the newest others remain")
        recent.remove("b")
        try check(recent.keys == ["c", "e"], "remove forgets a key")
    }

    private static func selectionFindsAnEventInItsOwnSessionBucket() throws {
        let inHashSession = try canonicalEvent("s#1", 1, "agent_message")
        let other = try canonicalEvent("s2", 1, "agent_message")
        let buckets = ["s#1": [inHashSession], "s2": [other]]
        try check(MonitorSelection.contains(inHashSession.id, in: buckets), "a session id containing # still resolves")
        try check(MonitorSelection.contains(other.id, in: buckets), "an event is found in its session's bucket")
        try check(!MonitorSelection.contains("s2#missing", in: buckets), "a missing event is not found")
        try check(!MonitorSelection.contains("unknown#x", in: buckets), "an unknown session's event is not found")
    }

    private static func trailingItemMatchesFullGrouping() throws {
        let ts = "2026-08-07T00:00:00.000Z"
        let events = [
            try canonicalEvent("s", 1, "user_message", ts: ts, turnId: "t"),
            try canonicalEvent("s", 2, "tool_call", ts: ts, turnId: "t"),
            try canonicalEvent("s", 3, "tool_call", ts: ts, turnId: "t"),
            try canonicalEvent("s", 4, "tool_call", ts: ts, turnId: "u"),
            try canonicalEvent("s", 5, "tool_call", ts: ts, turnId: "u")
        ]
        for count in 0...events.count {
            let prefix = Array(events.prefix(count))
            try check(EventTimeline.lastItem(prefix) == EventTimeline.group(prefix).last,
                      "the trailing scan must equal the full grouping's last item (\(count) events)")
        }
        let noTurn = [try canonicalEvent("s", 1, "tool_call"), try canonicalEvent("s", 2, "tool_call")]
        try check(EventTimeline.lastItem(noTurn) == EventTimeline.group(noTurn).last, "calls without a turn do not join")
    }

    private static func eventsFrameUpsertReplacesInsertsAndOrders() throws {
        let start = try canonicalEvent("s1", 1, "turn_start", ts: "2026-08-07T00:00:00.000Z", key: "turn:t1")
        let running = try canonicalEvent("s1", 2, "tool_call", ts: "2026-08-07T00:00:02.000Z", key: "tool:c1",
                                         title: "Bash: make", status: "running")
        let bucket = upsertMonitorEvents([running, start], into: [], limit: 10)
        try check(bucket.map(\.id) == ["s1#turn:t1", "s1#tool:c1"], "inserted events must sort by ts")

        // The call finishes: same id, same first-seen ts, new status/body.
        let finished = try canonicalEvent("s1", 2, "tool_call", ts: "2026-08-07T00:00:02.000Z", key: "tool:c1",
                                          title: "Bash: make", body: "ok", status: "completed")
        // A message first seen earlier than the call but delivered later, and
        // a same-ms event whose lower sequence must lead.
        let earlier = try canonicalEvent("s1", 3, "agent_message", ts: "2026-08-07T00:00:01.000Z", key: "msg:t1:1", body: "hi")
        let tieLate = try canonicalEvent("s1", 5, "agent_thought", ts: "2026-08-07T00:00:03.000Z", key: "thought:t1:2")
        let tieEarly = try canonicalEvent("s1", 4, "agent_message", ts: "2026-08-07T00:00:03.000Z", key: "msg:t1:2")
        let next = upsertMonitorEvents([finished, tieLate, earlier, tieEarly], into: bucket, limit: 10)
        try check(next.map(\.key) == ["turn:t1", "msg:t1:1", "tool:c1", "msg:t1:2", "thought:t1:2"],
                  "upsert must order by ts then sequence: \(next.map(\.key))")
        try check(next.filter { $0.key == "tool:c1" }.count == 1, "the same id must replace, never duplicate")
        try check(next.first { $0.key == "tool:c1" }?.status == "completed", "the replacement carries the new status")
        try check(next.first { $0.key == "tool:c1" }?.body == "ok", "the replacement carries the new body")

        let capped = upsertMonitorEvents([try canonicalEvent("s1", 6, "turn_end", ts: "2026-08-07T00:00:04.000Z")],
                                         into: next, limit: 3)
        try check(capped.map(\.sequence) == [4, 5, 6], "past the limit only the oldest events fall off")
        try check(upsertMonitorEvents([], into: next, limit: 10) == next, "an empty frame changes nothing")
    }

    private static func sessionUsageDecodesOnlyKnownNumbers() throws {
        try check(SessionUsage(nil) == nil && SessionUsage(.null) == nil, "no usage object means no usage")
        try check(SessionUsage(.object(["inputTokens": .null, "outputTokens": .null])) == nil,
                  "an all-null usage object means the provider said nothing")
        let partial = SessionUsage(.object(["inputTokens": .number(10), "outputTokens": .number(5)]))
        try check(partial?.total == 15, "total falls back to input + output")
        try check(partial?.contextFraction == nil, "no context gauge without a window")
        let full = SessionUsage(.object(["contextUsed": .number(300_000), "contextWindow": .number(200_000)]))
        try check(full?.contextFraction == 1, "the context fraction is clamped to 1")
        try check(formatTokenCount(950) == "950" && formatTokenCount(1_280) == "1.3K"
                  && formatTokenCount(258_400) == "258K" && formatTokenCount(1_260_000) == "1.3M",
                  "token counts abbreviate for small labels")
        guard let session = GatewaySession(.object([
            "sessionId": .string("s"), "usage": .object(["totalTokens": .number(7)]),
            "usagePartial": .bool(true), "capabilities": .array([.string("status"), .number(1)])
        ])) else { throw CheckError.failed("usage session fixture did not decode") }
        try check(session.usage?.total == 7 && session.usagePartial, "session usage fields decode")
        try check(session.capabilities == ["status"], "non-string capabilities are ignored")
        try check(session.model == nil && session.withModel("codex") == "codex", "a nil model adds no tag")
    }

    /// Replays sidecar/test/fixtures/restart-blockers.json — the same file
    /// test/monitor-control.test.js feeds to MonitorState.restartBlockers().
    /// The updater refuses to activate whenever either side reports a blocker,
    /// so the two must produce byte-identical strings for identical input.
    private static func restartBlockersMatchTheSharedGatewayContract() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repoRoot.appendingPathComponent("sidecar/test/fixtures/restart-blockers.json")
        guard let data = try? Data(contentsOf: fixtureURL),
              let cases = try? decodeJSONValue(data).objectValue?.array("cases"), !cases.isEmpty else {
            throw CheckError.failed("shared restart-blocker fixture is missing or unreadable at \(fixtureURL.path)")
        }

        for entry in cases {
            guard let fixture = entry.objectValue,
                  let name = fixture.string("name"),
                  let expected = fixture.array("expected")?.compactMap({ $0.stringValue }) else {
                throw CheckError.failed("malformed restart-blocker fixture case")
            }
            let sessions = (fixture.array("sessions") ?? []).compactMap { value -> GatewaySession? in
                guard var object = value.objectValue else { return nil }
                // The fixture states only what the rule reads; the rest is
                // whatever a decoded Gateway record would otherwise carry.
                object["provider"] = object["provider"] ?? .string("codex")
                object["cwd"] = object["cwd"] ?? .string("/tmp/project")
                return GatewaySession(.object(object))
            }
            let records: ([JSONValue]?, String) -> [MonitorRecord] = { values, kind in
                (values ?? []).enumerated().map { MonitorRecord($0.element, fallbackKind: kind, index: $0.offset) }
            }
            let blockers = restartBlockerLabels(
                sessions: sessions,
                tasks: records(fixture.array("tasks"), "task"),
                inbox: records(fixture.array("inbox"), "inbox")
            )
            try check(blockers == expected, "restart blockers diverged from the Gateway contract (\(name)): got \(blockers), expected \(expected)")
        }
    }

    /// A rolled-back runtime stops accepting app updates on purpose. If the UI
    /// does not say so, the machine just looks stuck on an old build.
    private static func runtimeInspectionSurfacesAPinnedRollback() throws {
        func inspection(pinned: Bool) throws -> RuntimeInspection {
            var current: [String: JSONValue] = [
                "runtimeRoot": .string("/r/versions/1.0.0-old"),
                "gatewayVersion": .string("1.0.0"),
                "gatewayBuildId": .string("old")
            ]
            if pinned { current["pinned"] = .bool(true) }
            guard let decoded = RuntimeInspection(.object([
                "runtimeRoot": .string("/r"),
                "current": .object(current),
                "versions": .array([])
            ])) else { throw CheckError.failed("runtime inspection fixture failed") }
            return decoded
        }
        let pinned = try inspection(pinned: true)
        let unpinned = try inspection(pinned: false)
        try check(pinned.currentPinned, "a pinned current runtime must decode as pinned")
        try check(pinned.pinnedNotice != nil, "a pinned runtime must explain why updates stopped")
        try check(!unpinned.currentPinned, "an unpinned runtime must not claim to be pinned")
        try check(unpinned.pinnedNotice == nil, "an unpinned runtime must show no pin notice")
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
