import Foundation

@main
enum MonitorModelChecks {
    static func main() throws {
        try snapshotDecodesSessionsEventsTasksAndInbox()
        try snapshotRejectsUnsupportedSchemaMajorWithoutPartialDecode()
        try compatibilityDistinguishesIncompatibleFromUpdateRequired()
        try monitorApiVersionParsesMajorMinorAndRejectsMalformedStrings()
        try monitorMetaDecodesGatewayIdentityAndToleratesNullSetupValues()
        try monitorMetaRejectsMissingMonitorApiVersion()
        try monitorClientErrorDecodesCodeAndErrorFromHTTPBody()
        try everyStableFailureCodeCarriesDistinctActionableGuidance()
        try runtimeSplitAnnotationSurfacesAsAWarning()
        try agentCatalogDecodesInstallAndEnabledState()
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
        try graphProjectionGroupsFrontdoorsAndAssignsWorkerLanes()
        try graphProjectionBuildsPromptReturnTurnsAndUsesCanvasHeight()
        try graphProjectionFollowsOnlyTheCurrentLiveTurn()
        try graphProjectionBoundsLargeLiveHistories()
        try eventBodyTextSurfacesReadableTextInsteadOfTheJSONEnvelope()
        try restartBlockersMatchTheSharedGatewayContract()
        try runtimeInspectionSurfacesAPinnedRollback()
        try mergedChunkBodyRebuildsTheWholeStreamedMessage()
        print("Swift model checks passed")
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
        let data = Data(#"""
        {
          "schemaVersion":1,
          "monitorApiVersion":"1.0",
          "connected":true,
          "gateway":{"gatewayVersion":"1.3.1"},
          "sessions":[{"sessionId":"s1","provider":"codex","status":"running","cwd":"/tmp/project","eventCount":2}],
          "events":{"s1":[{"sessionId":"s1","sequence":0,"type":"turn_start","ts":"2026-08-07T00:00:00.000Z","text":"work"}]},
          "historySessions":[{"sessionId":"old","provider":"claude","status":"ready","cwd":"/tmp/project","opener":"codex","openerInstanceId":"main-old"}],
          "historyEvents":{"old":[{"sessionId":"old","sequence":1,"type":"turn_end","ts":"2026-08-06T23:59:00.000Z"}]},
          "tasks":[{"taskId":"t1","status":"working","statusMessage":"running"}],
          "inbox":[{"inboxId":"i1","status":"pending","type":"permission_request","sessionId":"s1"}]
        }
        """#.utf8)
        let snapshot = try MonitorSnapshot.decode(data)
        try check(snapshot.schemaVersion == 1, "snapshot should decode the schema version")
        try check(snapshot.monitorApiVersion == "1.0", "snapshot should decode the monitor API version")
        try check(snapshot.connected, "snapshot should be connected")
        try check(snapshot.streaming, "snapshot should default streaming to connected for compatibility")
        try check(snapshot.sessions.first?.sessionId == "s1", "session decode failed")
        try check(snapshot.eventsBySession["s1"]?.first?.type == "turn_start", "event decode failed")
        try check(snapshot.historySessions.first?.sessionId == "old", "history session decode failed")
        try check(snapshot.historyEventsBySession["old"]?.first?.type == "turn_end", "history event decode failed")
        try check(snapshot.tasks.first?.id == "t1", "task decode failed")
        try check(snapshot.inbox.first?.id == "i1", "inbox decode failed")
    }

    private static func snapshotRejectsUnsupportedSchemaMajorWithoutPartialDecode() throws {
        let data = Data(#"""
        {
          "schemaVersion":2,
          "monitorApiVersion":"1.0",
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
        let missingApiVersion = Data(#"{"schemaVersion":1,"connected":true,"sessions":[]}"#.utf8)
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
            #"{"monitorApiVersion":"1.0"}"#, // missing schemaVersion entirely
            #"{"schemaVersion":"1","monitorApiVersion":"1.0"}"#, // schemaVersion is not a number
            #"{"schemaVersion":1}"#, // missing monitorApiVersion entirely
            #"{"schemaVersion":1,"monitorApiVersion":"bad"}"#, // unparseable version string
            #"{"schemaVersion":1,"monitorApiVersion":"1"}"# // missing minor component
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
            #"{"schemaVersion":2,"monitorApiVersion":"1.0"}"#, // well-formed but unsupported schema major
            #"{"schemaVersion":1,"monitorApiVersion":"2.0"}"# // well-formed but unsupported API major
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
          "schemaVersion":1,
          "monitorApiVersion":"1.0",
          "gatewayIdentity":{"rootId":"root-1","gatewayApiVersion":1,"gatewayVersion":null,"gatewayBuildId":null},
          "capabilities":{"agentUpdates":true}
        }
        """#.utf8)
        let meta = try MonitorMeta.decode(data)
        try check(meta.schemaVersion == 1, "meta should decode the schema version")
        try check(meta.monitorApiVersion == "1.0", "meta should decode the monitor API version")
        try check(meta.gatewayIdentity.rootId == "root-1", "meta should decode the gateway identity root id")
        try check(meta.gatewayIdentity.gatewayApiVersion == 1, "meta should decode the gateway API version")
        try check(meta.gatewayIdentity.gatewayVersion == nil, "a missing Gateway setup value should decode as nil, not crash")
        try check(meta.gatewayIdentity.gatewayBuildId == nil, "a missing Gateway setup value should decode as nil, not crash")
        try check(meta.capabilities.objectValue?.bool("agentUpdates") == true, "capabilities should be preserved as additive JSON")
    }

    private static func monitorMetaRejectsMissingMonitorApiVersion() throws {
        let data = Data(#"{"schemaVersion":1,"gatewayIdentity":{},"capabilities":{}}"#.utf8)
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
        try check(frontdoors.count == 2, "Dashboard should list Frontdoors, not mapped Worker sessions")
        let codex = frontdoors.first { $0.id == "main-1" }
        try check(codex?.workers.count == 2, "workers with the same Frontdoor id should aggregate")
        try check(codex?.activeWorkerCount == 1, "Frontdoor activity should come from its current workers")
        try check(!frontdoors.contains(where: { $0.id == "legacy" }), "legacy sessions without a Frontdoor id must stay out of the UI")
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
        try check(junkTitle.displayName == "Codex Frontdoor", "a tool-call title is rejected as a name")
        try check(folderOnly.displayName == "proj", "the working folder names the Frontdoor")
        try check(bare.displayName == "Codex Frontdoor", "with neither, the provider label remains")
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

        let projection = GraphProjection.make(sessions: [root, gatewayWorker], eventsBySession: [:])
        try check(projection.groups.count == 1, "Branch should keep one Frontdoor trunk")
        try check(projection.workerLaneCount == 1, "Branch worker count must exclude the local root lane")

        // The menu-bar popover stacks these lanes vertically instead of laying
        // them out along X, so it needs the trunk order made explicit.
        let stacked = projection.lanesOrderedByTrunk
        try check(stacked.count == projection.lanes.count, "stacked lane order must keep every lane exactly once")
        try check(Set(stacked.map(\.id)).count == stacked.count, "stacked lane order must not duplicate a lane")
        try check(stacked.first?.session.isFrontdoorRecord == true, "each group's Frontdoor root must lead its workers")
        try check(stacked.last?.session.sessionId == gatewayWorker.sessionId, "workers must follow their Frontdoor root")
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
        try check(runtimeSplitWarning(gateway: .object(["gatewayVersion": .string("1.3.1")])) == nil, "no annotation, no warning")
        try check(runtimeSplitWarning(gateway: nil) == nil, "no gateway info, no warning")
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

    private static func graphProjectionGroupsFrontdoorsAndAssignsWorkerLanes() throws {
        let sessionValue = JSONValue.object([
            "sessionId": .string("s1"), "provider": .string("codex"), "status": .string("running"),
            "cwd": .string("/tmp/project"), "opener": .string("grok"), "createdAt": .string("2026-08-07T00:00:00.000Z"),
            "turnId": .string("t1")
        ])
        let eventValue = JSONValue.object([
            "sessionId": .string("s1"), "sequence": .number(0), "type": .string("turn_start"),
            "ts": .string("2026-08-07T00:05:00.000Z"), "turnId": .string("t1")
        ])
        guard let session = GatewaySession(sessionValue), let event = MonitorEvent(eventValue) else {
            throw CheckError.failed("fixture creation failed")
        }
        let projection = GraphProjection.make(sessions: [session], eventsBySession: ["s1": [event]])
        try check(projection.groups.count == 1, "frontdoor grouping failed")
        try check(projection.groups.first?.opener == "grok", "frontdoor opener failed")
        try check(projection.lanes.first?.turns.count == 1, "turn projection failed")
        try check((projection.lanes.first?.laneX ?? 0) > (projection.groups.first?.trunkX ?? 0), "lane placement failed")
    }

    private static func graphProjectionBuildsPromptReturnTurnsAndUsesCanvasHeight() throws {
        // Two sessions running concurrently: each contributes its own live turn,
        // which is how more than one node ever reaches the canvas at once.
        func running(_ id: String, turnId: String) -> JSONValue {
            .object([
                "sessionId": .string(id), "provider": .string("codex"), "status": .string("running"),
                "cwd": .string("/tmp/project"), "opener": .string("codex"),
                "openerInstanceId": .string("main-1"), "turnId": .string(turnId)
            ])
        }
        let firstFixtures: [[String: JSONValue]] = [
            ["sequence": .number(0), "type": .string("turn_start"), "ts": .string("2026-08-07T00:09:00.000Z"), "turnId": .string("t1"), "text": .string("first prompt")],
            ["sequence": .number(1), "type": .string("agent_message_chunk"), "ts": .string("2026-08-07T00:09:01.000Z"), "turnId": .string("t1"), "text": .string("progress")],
            ["sequence": .number(2), "type": .string("tool_call"), "ts": .string("2026-08-07T00:09:02.000Z"), "turnId": .string("t1")],
            ["sequence": .number(3), "type": .string("agent_message_chunk"), "ts": .string("2026-08-07T00:09:03.000Z"), "turnId": .string("t1"), "text": .string("final answer")],
            ["sequence": .number(4), "type": .string("tool_call_update"), "ts": .string("2026-08-07T00:09:04.000Z"), "turnId": .string("t1")]
        ]
        let secondFixtures: [[String: JSONValue]] = [
            ["sequence": .number(5), "type": .string("turn_start"), "ts": .string("2026-08-07T00:09:30.000Z"), "turnId": .string("t2"), "text": .string("second prompt")],
            ["sequence": .number(6), "type": .string("agent_message_chunk"), "ts": .string("2026-08-07T00:09:31.000Z"), "turnId": .string("t2"), "text": .string("second return")]
        ]
        guard let first = GatewaySession(running("s1", turnId: "t1")),
              let second = GatewaySession(running("s2", turnId: "t2")) else {
            throw CheckError.failed("turn fixture creation failed")
        }
        func events(_ fixtures: [[String: JSONValue]], sessionId: String) -> [MonitorEvent] {
            fixtures.compactMap { fixture in
                var value = fixture
                value["sessionId"] = .string(sessionId)
                return MonitorEvent(.object(value))
            }
        }
        let projection = GraphProjection.make(
            sessions: [first, second],
            eventsBySession: ["s1": events(firstFixtures, sessionId: "s1"), "s2": events(secondFixtures, sessionId: "s2")]
        )
        let turns = projection.lanes.flatMap(\.turns)
        try check(turns.count == 2, "each live session should collapse into one human-readable turn")
        try check(turns[0].prompt == "first prompt", "prompt should come from turn_start")
        try check(turns[0].response == "final answer", "return should keep the final segment after a tool boundary")
        try check(turns[0].events.count == 5, "a turn should retain every event for node detail inspection")
        try check(turns[0].progress == 0.1 && turns[1].progress == 0.9, "short live bursts should use the canvas height")
    }

    private static func graphProjectionFollowsOnlyTheCurrentLiveTurn() throws {
        let sessionValue = JSONValue.object([
            "sessionId": .string("s1"), "provider": .string("codex"), "status": .string("running"),
            "cwd": .string("/tmp/project"), "opener": .string("codex"),
            "openerInstanceId": .string("main-1"), "turnId": .string("current")
        ])
        let fixtures: [[String: JSONValue]] = [
            ["sequence": .number(0), "type": .string("turn_start"), "ts": .string("2026-08-07T00:00:00.000Z"), "turnId": .string("previous"), "text": .string("old prompt")],
            ["sequence": .number(1), "type": .string("turn_end"), "ts": .string("2026-08-07T00:01:00.000Z"), "turnId": .string("previous")],
            ["sequence": .number(2), "type": .string("turn_start"), "ts": .string("2026-08-07T00:02:00.000Z"), "turnId": .string("current"), "text": .string("long running prompt")],
            ["sequence": .number(3), "type": .string("turn_start"), "ts": .string("2026-08-07T00:59:00.000Z"), "turnId": .string("recent-history"), "text": .string("must stay out of Live")],
            ["sequence": .number(4), "type": .string("turn_end"), "ts": .string("2026-08-07T00:59:01.000Z"), "turnId": .string("recent-history")]
        ]
        guard let session = GatewaySession(sessionValue) else {
            throw CheckError.failed("live turn fixture creation failed")
        }
        let events = fixtures.compactMap { fixture -> MonitorEvent? in
            var value = fixture
            value["sessionId"] = .string("s1")
            return MonitorEvent(.object(value))
        }

        let projection = GraphProjection.make(sessions: [session], eventsBySession: ["s1": events])
        let turns = projection.lanes.first?.turns ?? []
        try check(turns.count == 1, "live branch should contain only the current turn")
        try check(turns.first?.turnId == "current", "live branch should follow the Gateway session turn id")
        try check(turns.first?.prompt == "long running prompt", "a long-running current turn must ignore the history window")
    }

    private static func graphProjectionBoundsLargeLiveHistories() throws {
        let sessionValue = JSONValue.object([
            "sessionId": .string("large"), "provider": .string("codex"), "status": .string("running"),
            "cwd": .string("/tmp/project"), "opener": .string("codex"),
            "openerInstanceId": .string("main-large"), "turnId": .string("active")
        ])
        guard let session = GatewaySession(sessionValue) else {
            throw CheckError.failed("large graph fixture creation failed")
        }
        var values: [MonitorEvent] = []
        for index in 0..<180 {
            for (offset, type) in ["turn_start", "turn_end"].enumerated() {
                let value = JSONValue.object([
                    "sessionId": .string("large"), "sequence": .number(Double(index * 2 + offset)),
                    "type": .string(type), "ts": .string("2026-08-07T00:09:00.000Z"),
                    "turnId": .string("done-\(index)"), "text": .string("done")
                ])
                if let event = MonitorEvent(value) { values.append(event) }
            }
        }
        if let start = MonitorEvent(.object([
            "sessionId": .string("large"), "sequence": .number(1_000), "type": .string("turn_start"),
            "ts": .string("2026-08-07T00:09:30.000Z"), "turnId": .string("active"),
            "text": .string(String(repeating: "p", count: 6_000))
        ])) { values.append(start) }
        for index in 0..<300 {
            let value = JSONValue.object([
                "sessionId": .string("large"), "sequence": .number(Double(1_001 + index)),
                "type": .string("agent_message_chunk"), "ts": .string("2026-08-07T00:09:31.000Z"),
                "turnId": .string("active"), "text": .string(String(repeating: "r", count: 100))
            ])
            if let event = MonitorEvent(value) { values.append(event) }
        }

        let projection = GraphProjection.make(sessions: [session], eventsBySession: ["large": values])
        try check(projection.turnCount <= 120, "live projection should cap the rendered turn count")
        guard let active = projection.lanes.first?.turns.first(where: { $0.turnId == "active" }) else {
            throw CheckError.failed("large active turn should stay pinned")
        }
        try check(active.events.count <= 160, "a live turn should cap retained detail events")
        try check(active.prompt.count <= 4_001, "a live prompt should be bounded")
        try check(active.response.count <= 12_001, "a live response should be bounded")
    }

    /// The detail panes lead with `bodyText`, so it must follow the producers'
    /// real shapes: `src/gateway-service.js` flattens chunks into `text` but
    /// serializes tool updates into `text` while keeping the real object in
    /// `data` — reading `text` there would print JSON, which is exactly what
    /// the body is supposed to replace.
    private static func eventBodyTextSurfacesReadableTextInsteadOfTheJSONEnvelope() throws {
        func event(_ fields: [String: JSONValue]) throws -> MonitorEvent {
            var value = fields
            value["sessionId"] = .string("s1")
            value["ts"] = .string("2026-08-07T00:00:00.000Z")
            guard let event = MonitorEvent(.object(value)) else {
                throw CheckError.failed("body text fixture creation failed")
            }
            return event
        }

        let chunk = try event([
            "sequence": .number(0), "type": .string("agent_message_chunk"),
            "text": .string("리팩터링을 마쳤습니다.")
        ])
        try check(chunk.bodyText == "리팩터링을 마쳤습니다.", "a chunk's top-level text is the body verbatim")

        // The gateway's generic tail: `text` is the serialized update, `data`
        // the real one, and the result sits in a nested ACP content wrapper.
        let update = try event([
            "sequence": .number(1), "type": .string("tool_call_update"),
            "text": .string(#"{"sessionUpdate":"tool_call_update","toolCallId":"tool-1"}"#),
            "data": .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tool-1"),
                "status": .string("completed"),
                "title": .string("Read file"),
                "content": .array([
                    .object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("line one")])]),
                    .object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("line two")])])
                ])
            ])
        ])
        guard let updateBody = update.bodyText else {
            throw CheckError.failed("a completed tool call must surface what it returned")
        }
        try check(updateBody.contains("line one") && updateBody.contains("line two"), "every text part of the result must be joined into the body")
        try check(updateBody.contains("Read file"), "the tool's title should introduce its result")
        try check(!updateBody.contains("toolCallId"), "the serialized envelope must never leak into the body")

        // Nothing readable: the raw JSON view stays the only sensible display.
        let ended = try event(["sequence": .number(2), "type": .string("turn_end"), "stopReason": .string("end_turn")])
        try check(ended.bodyText == nil, "an event with no text must report no body rather than a fabricated one")

        let started = try event([
            "sequence": .number(3), "type": .string("tool_call"),
            "text": .string(#"{"sessionUpdate":"tool_call"}"#),
            "data": .object([
                "toolCallId": .string("tool-2"), "title": .string("Edit file"),
                "rawInput": .object(["path": .string("/tmp/a.txt")])
            ])
        ])
        try check(started.bodyText?.contains("Edit file") == true, "a starting tool call is identified by its title")
        try check(started.bodyText?.contains("/tmp/a.txt") == true, "a starting tool call should summarize its input")

        // local-transcript.js writes a human summary into `text` and emits no
        // `data`, so the same tool types must stay readable from that producer.
        let local = try event([
            "sequence": .number(4), "type": .string("tool_call"),
            "source": .string("local-transcript"), "toolCallId": .string("call-1"),
            "text": .string("exec: sqlite3 state.db")
        ])
        try check(local.bodyText == "exec: sqlite3 state.db", "a local transcript summary is already the body")

        let permission = try event([
            "sequence": .number(5), "type": .string("permission_request"),
            "requestId": .string("req-1"),
            "toolCall": .object(["toolCallId": .string("tool-3"), "title": .string("Edit file")])
        ])
        try check(permission.bodyText == "Edit file · 권한 요청", "a permission request should name the tool it is asking about")

        // Oversized updates keep only a truncated JSON head in `text`.
        let truncated = try event([
            "sequence": .number(6), "type": .string("tool_call_update"),
            "text": .string(#"{"sessionUpdate":"tool_call_update","rawOutput":"가가가"#),
            "dataTruncated": .bool(true)
        ])
        try check(truncated.bodyText == nil, "a truncated JSON head must not be presented as readable text")
    }

    /// Replays test/fixtures/restart-blockers.json — the same file
    /// test/monitor-control.test.js feeds to MonitorState.restartBlockers().
    /// The updater refuses to activate whenever either side reports a blocker,
    /// so the two must produce byte-identical strings for identical input.
    private static func restartBlockersMatchTheSharedGatewayContract() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repoRoot.appendingPathComponent("test/fixtures/restart-blockers.json")
        guard let data = try? Data(contentsOf: fixtureURL),
              let cases = try? decodeJSONValue(data).objectValue?.array("cases"), !cases.isEmpty else {
            throw CheckError.failed("shared restart-blocker fixture is missing or unreadable at \(fixtureURL.path)")
        }

        for entry in cases {
            guard let fixture = entry.objectValue,
                  let name = fixture.string("name"),
                  let expected = fixture.array("expected")?.compactMap(\.stringValue) else {
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

    /// A streamed answer is many chunk events; selecting any single one (the
    /// sequence diagram's ×N node keeps the *last* fragment) must still show
    /// the whole message, not its tail.
    private static func mergedChunkBodyRebuildsTheWholeStreamedMessage() throws {
        func event(_ fields: [String: JSONValue]) throws -> MonitorEvent {
            var value = fields
            value["sessionId"] = .string("s1")
            value["turnId"] = value["turnId"] ?? .string("t1")
            value["ts"] = .string("2026-08-07T00:00:00.000Z")
            guard let event = MonitorEvent(.object(value)) else {
                throw CheckError.failed("merged chunk fixture creation failed")
            }
            return event
        }

        // Gateway token deltas: joined verbatim, paragraph break at the same
        // boundaries the gateway's own result logic uses.
        let bucket = try [
            event(["sequence": .number(0), "type": .string("turn_start"), "text": .string("인사해")]),
            event(["sequence": .number(1), "type": .string("agent_message_chunk"), "text": .string("안")]),
            event(["sequence": .number(2), "type": .string("agent_message_chunk"), "text": .string("녕")]),
            event(["sequence": .number(3), "type": .string("tool_call"), "text": .string("{}")]),
            event(["sequence": .number(4), "type": .string("agent_message_chunk"), "text": .string("하세요")])
        ]
        guard let merged = mergedChunkBody(for: bucket[2], in: bucket) else {
            throw CheckError.failed("a multi-fragment stream must merge")
        }
        try check(merged.text == "안녕\n\n하세요", "token deltas join verbatim and break at tool boundaries")
        try check(merged.fragments == 3, "every fragment of the turn counts")

        // Fragments from another turn must not bleed in.
        let otherTurn = try event(["sequence": .number(9), "type": .string("agent_message_chunk"), "text": .string("다른 턴"), "turnId": .string("t2")])
        guard let scoped = mergedChunkBody(for: bucket[1], in: bucket + [otherTurn]) else {
            throw CheckError.failed("turn-scoped merge failed")
        }
        try check(!scoped.text.contains("다른 턴"), "merging is scoped to the selected fragment's turn")

        // Local transcript chunks are complete messages: one paragraph each.
        let localBucket = try [
            event(["sequence": .number(0), "type": .string("agent_message_chunk"), "source": .string("local-transcript"), "text": .string("첫 메시지")]),
            event(["sequence": .number(1), "type": .string("agent_message_chunk"), "source": .string("local-transcript"), "text": .string("둘째 메시지")])
        ]
        guard let local = mergedChunkBody(for: localBucket[1], in: localBucket) else {
            throw CheckError.failed("local chunks must merge")
        }
        try check(local.text == "첫 메시지\n\n둘째 메시지", "complete local messages must not be smashed together")

        // A lone fragment and a non-chunk event both defer to bodyText.
        let single = try event(["sequence": .number(0), "type": .string("agent_message_chunk"), "text": .string("혼자")])
        try check(mergedChunkBody(for: single, in: [single]) == nil, "a lone fragment needs no merging")
        try check(mergedChunkBody(for: bucket[3], in: bucket) == nil, "non-chunk events never merge")
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
